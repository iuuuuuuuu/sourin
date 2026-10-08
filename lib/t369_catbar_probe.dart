/*
 * t369 —— 「TVBox 源分类栏不显示」修复的**真启动**取证（同产物、只换 DLL 的 A/B）
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ── 被验证的缺陷（Owner 原话 m17884）─────────────────────────────────────
 *   「tvbox源的确实没做完」
 *   现象：TVBox 系内容源（360 / tyyszy / cj-2 / 154 / api-2 …）的浏览页
 *   **没有分类切换栏**，只有一列卡片；而内置 `cctv.js` 的分类栏正常。
 *
 * ── 根因（已由 t365/t366 定位并修复）─────────────────────────────────────
 *   `rust/sourin_core/src/plugins/mod.rs:1892` 原来写死 `plugin.categories()`
 *   —— 假定 `categories` 一定是**方法**。但 TVBox 转换出来的插件把它写成
 *   **数据数组** `categories: [ {id,name}, … ]` ⇒ JS 抛 `not a function`
 *   ⇒ Rust 侧 `ProviderError::parse` ⇒ Dart 侧 `jlist()` 抛
 *   `SourinCoreException` ⇒ `browse_page.dart:92-99` 的 `catch (_)` 吞掉
 *   ⇒ `_categories` 保持 `[]` ⇒ `:212 if (_categories.isNotEmpty …)` 为假
 *   ⇒ **分类栏整条不渲染**（列表本身照常，因为 `get_list` 走的是另一条路）。
 *
 *   修法：`:1895` 换成
 *     `(typeof plugin.categories === 'function' ? plugin.categories() : (plugin.categories || []))`
 *
 * ── 为什么必须真启动，FFI A/B 不算数 ─────────────────────────────────────
 *   t366 已经用 FFI 直连证明「新 DLL 返回 51 个分类、旧 DLL 报 not a function」
 *   （pass=17 fail=0）。但那**只证明了数据层**。Owner 的铁律是
 *   「交付前必须自跑完整实测：真启动、真播放、真截图」——
 *   数据对不等于**像素上真的画出来了**：`_categories.isNotEmpty` 到
 *   「屏幕上有那一排胶囊」之间还隔着 sliver 布局、ListView 懒构建、
 *   主题颜色、以及那个 `catch (_)` 到底吞没吞。所以这一层必须单独测。
 *
 * ── A/B 设计：同一份产物，只换一个 DLL ───────────────────────────────────
 *   ★★★ 这里**不重新编译**。两个臂用的是**同一个 exe、同一个 app.so、
 *       同一个数据目录、同一个窗口尺寸**，唯一变量是私有运行目录里的
 *       `sourin_core.dll`：
 *         · 旧臂 = 交付包里那个（sha16 `9D3E9D3F7A9361FB`，不含修复）
 *         · 新臂 = `rust/.../target/release/sourin_core.dll`
 *                  （sha16 `BDB595C7D5F06A2B`，含修复）
 *   为什么这样最干净：重编译两个 revision 再 diff 只能说明「两个构建不同」，
 *   说明不了「是那一行造成的」；只换 DLL 则把变量压到 1 个二进制文件，
 *   而且正好就是**部署问题本身**（"这个 DLL 该不该换掉交付里那个"）。
 *   `lib/core/ffi.dart:165-174` 只按裸文件名 `DynamicLibrary.open('sourin_core.dll')`
 *   加载 ⇒ 换目录里那个文件即可，代码零改动。
 *
 * ── 判据的骨架：**臂中立的不变量**，而不是「新臂该有、旧臂该没有」──────
 *   如果写成「新臂必须有分类栏 / 旧臂必须没有」，那两次运行各自都只是
 *   在复述预期，合起来也不构成对照（#522：反向找一个容器总能成功）。
 *   所以这里断言的是**两臂都必须成立的不变量**：
 *     ⑤ 树里有分类 ⟺ FFI 真的给了分类
 *     ⑥ 判别串在 ⟺ FFI 给了 51 个分类
 *   旧臂：两边都假 ⇒ ✓（这就是对照：**页面确实活了、列表确实出来了，
 *                        只是分类栏没有**）
 *   新臂：两边都真 ⇒ ✓
 *   任一臂若出现「FFI 给了但 UI 没画」或「UI 画了但 FFI 没给」⇒ ✗。
 *   ★ ② 的「列表卡片真的渲染了」是这套设计的**承重墙**：
 *     它保证旧臂的「分类栏缺席」不是「整页没渲染」造成的假红。
 *
 * ── 判别串为什么是「科幻片」──────────────────────────────────────────────
 *   360 源的 8 个首页分区标题是：电影/连续剧/综艺/动漫/伦理片/动作片/
 *   喜剧片/爱情片（`.probe/t366-cat-ab/B-new/out/21_home_360.json`），
 *   而它的 51 个分类的**前 8 个与这 8 个标题逐字相同** ⇒
 *   只找 `Text('电影')` 会被首页分区卡片骗过。
 *   第 9 个分类「科幻片」不在任何分区标题里 ⇒ 唯一判别串。
 *   ★ 顺序也当判据用（`cats[8].name == '科幻片'`），这样上游接口若变了
 *     会**报错**而不是静默换成另一个词。
 *
 * ── 仪器纪律（本仓血泪）──────────────────────────────────────────────────
 *   · `exit()` 不展开 finally ⇒ 每条退出路径先 `finish()` 落产物。
 *   · 外壳用**生产本体** `SourinApp`（不是复刻）⇒ FTheme → FScaffold →
 *     Material(transparency) 天然满足；复刻漏 Material 会让 InkWell 抛
 *     `Null check operator used on a null value` 并把整页换成 ErrorWidget，
 *     真因只在 stderr。
 *   · 浏览页走**生产的 Navigator + 生产的 MaterialPageRoute**（与
 *     `shell.dart:3769 _openBrowse` 构造的是同一个），不是另起一个 App。
 *   · 绝不动 Owner 的鼠标：全程程序化，零真实指针事件。
 *   · 窗口必须 `show()`，否则引擎可能整帧不产出 ⇒ `toImage()` 拿退化图
 *     ⇒ 「只有 1 种颜色」会被判成假绿。
 *   · 刻意**不**调 `windowManager.focus()`（生产 `shell.dart:399` 有）
 *     —— 那会抢走 Owner 当前窗口的焦点。
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
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/browse_page.dart';

// ══════════════════════════════════════════════════════════════════════════
// 常量
// ══════════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 运行标签：**运行时**从运行目录的身份标记读出（见 [main]），
/// 不是编译期常量。
///
/// ★★★ 为什么不能是 `String.fromEnvironment`：
///   A/B 两臂必须用**同一份产物**（同一个 exe + 同一个 app.so），
///   否则「读数变了」就可能只是构建差异。而 `fromEnvironment` 是编译期的
///   ⇒ 给两臂不同 tag 就要编译两次 ⇒ 产物不同 ⇒ 对照被污染。
///   所以 tag 改成运行时读：一次构建，两臂共用，各自从
///   `t369-dll-identity.txt`（由 runner 用**算出来的 sha16** 写入）取名。
String _tag = 'unknown';

/// 编译期兜底（直接 `flutter run` 时没有 runner 写标记，用它）。
const String _tagFallback = String.fromEnvironment('T369_TAG', defaultValue: '');

/// 被验证的内容源（TVBox 系；分类是**数据数组**形态）。
const String _provider = '360';

/// 唯一判别串 —— 第 9 个分类（见文件头说明）。
const String _discriminator = '科幻片';

/// 判别串的**阴性对照**：一个不可能存在的分类名。
/// 用途：证明 `findText` 真的会返回 null，而不是「找什么都找得到」。
/// 没有这一条，旧臂的「没找到」就无法与「仪器坏了」区分。
const String _discriminatorNeg = '这个分类不存在XYZ';

/// ★★★ 这里**故意不写死**期望条目。
/// 曾经的写法是 `const String _expectItem = '铁笼斗士';`，取自
/// `.probe/t366-cat-ab/B-new/out/20_list_360.json` —— 那是 t366 用
/// `get_list(360, category_id:"1")` 拿到的第 1 条。但本探针挂的是
/// `BrowsePage(categoryId: '')`，上游对**空分类**返回的是**另一批**条目
/// ⇒ 列表其实渲染出来了，探针却找不到那个写死的串，误报
/// `INSTRUMENT-FAILURE`（实测踩到，见 `.probe/t369-old-00-list-missing.png`）。
/// 正确做法：期望条目从**本臂自己的 FFI 读数**（① 段的 `listTitles`）派生。
/// 教训：判据里不许混进「上游对某个参数返回什么」这种外部变量。
///
/// t366 实测的分类总数（旧臂拿不到、新臂应拿到这个数）。
const int _expectCatCount = 51;

// ══════════════════════════════════════════════════════════════════════════
// 计数 / 日志
// ══════════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T369] $s');
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
  final f = File('$_outDir\\t369-catbar-$_tag.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T369] ★ 产物写入失败: $e');
  }
  debugPrint('[T369] 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B');
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

Element? findTextContaining(Element root, String s) =>
    findWidget(root, (w) => w is Text && (w.data ?? '').contains(s));

/// 收集树里所有 `Text.data`（分类名普查用）。
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

int elementCount(Element root) {
  var n = 0;
  void walk(Element e) {
    n++;
    e.visitChildren(walk);
  }

  walk(root);
  return n;
}

/// 元素的**全局矩形**（逻辑像素，与 `toImage(pixelRatio:1.0)` 同一坐标系）。
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
  final img = await ro.toImage(pixelRatio: 1.0);
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw StateError('toByteData 返回 null');
  final rgba = bd.buffer.asUint8List();
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t369-$_tag-$name.png';
  if (png != null) {
    File(path).writeAsBytesSync(png.buffer.asUint8List());
  }
  // 仪器自检：退化图（全黑/全白）只有 1~2 种颜色
  final seen = <int>{};
  for (var i = 0; i + 3 < rgba.length; i += 7 * 4) {
    seen.add((rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]);
  }
  return Shot(path, img.width, img.height, rgba, seen.length);
}

/// 某一行的游程编码（如实报告 x 范围）。
List<String> rowRle(Shot s, int y, {int maxSeg = 40}) {
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
  if (out.length > maxSeg) {
    return out.sublist(0, maxSeg)..add('…（共 ${out.length} 段，已截断）');
  }
  return out;
}

/// 矩形内与 [bg] 不同的像素数（判定「真的被光栅化了」）。
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

// ══════════════════════════════════════════════════════════════════════════
//  main
// ══════════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★★★ 先定 tag，**再**做任何会写文件的事 —— 否则产物名会串臂。
   *   来源优先级：运行目录的身份标记（runner 用算出来的 sha16 写的）
   *   > 编译期 dart-define > 'unknown'。
   *   标记是 `arm=old sha16=9D3E9D3F7A9361FB bytes=10594304` 这种形态，
   *   取 `arm` 字段当 tag；取不到就退回 dart-define。
   */
  if (_tagFallback.isNotEmpty) _tag = _tagFallback;
  try {
    final m = File(
      '${File(Platform.resolvedExecutable).parent.path}\\t369-dll-identity.txt',
    );
    if (m.existsSync()) {
      final line = m.readAsStringSync().trim();
      final mm = RegExp(r'arm=(\S+)').firstMatch(line);
      if (mm != null) _tag = mm.group(1)!;
    }
  } catch (e) {
    debugPrint('[T369] 读身份标记失败: $e');
  }

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
     *   `titleBarStyle: hidden` 才让自绘的 `_TitleBarHost` 占住顶部 ~39px，
     *   否则帧与用户看到的不是同一个东西、y 坐标全部错位。
     * ⚠️ 刻意不调 `windowManager.focus()`（生产 `shell.dart:399` 有）。
     * ★ 必须 `show()`：窗口不可见时引擎可能整帧不产出 ⇒ 退化图 ⇒ 假绿。
     */
    // ⚠️ 不能是 `const`：title 里嵌了**运行时**读出来的 `_tag`
    //    （见文件头「为什么 tag 不是编译期常量」）。
    final windowOptions = WindowOptions(
      size: const Size(1280, 800),
      minimumSize: const Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t369 分类栏取证 ($_tag)',
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
  debugPrint('[T369] ══════ TVBox 分类栏 —— 真启动取证 tag=$_tag ══════');

  // ── ⓪ 仪器自检 ────────────────────────────────────────────────────────
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  note('exe 目录 = $exeDir');
  final dll = File('$exeDir\\sourin_core.dll');
  note('本次加载的 DLL: 存在=${dll.existsSync()}'
      '${dll.existsSync() ? '  ${dll.lengthSync()} B  mtime=${dll.lastModifiedSync()}' : ''}');
  // ★ 身份不靠标签自证：读运行目录里由 runner 写下的身份标记
  final marker = File('$exeDir\\t369-dll-identity.txt');
  if (marker.existsSync()) {
    note('DLL 身份标记 = ${marker.readAsStringSync().trim()}');
  } else {
    note('DLL 身份标记缺失（runner 未写）');
  }

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ shell 已挂载（拿到 debugShellKey.currentState）', shellUp);
  if (!shellUp) {
    say('★ shell 没挂上 ⇒ 后续全部无意义，中止');
    say('[T369] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root != null);
  if (root == null) {
    say('[T369] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
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

  // ── ① 先直接问 FFI：这个源到底有没有分类（数据层的地面真值）──────────
  say('');
  say('──────── ① FFI 地面真值（SourinApi.getCategories("$_provider")）────────');

  var cats = <Category>[];
  String? catError;
  try {
    cats = await SourinApi.getCategories(_provider);
  } catch (e) {
    catError = e.toString();
  }
  if (catError != null) {
    say('getCategories 抛错 = $catError');
  } else {
    say('getCategories 返回 ${cats.length} 个分类');
    if (cats.isNotEmpty) {
      note('前 10 个 = ${cats.take(10).map((c) => '${c.id}:${c.name}').join('  ')}');
      note('第 9 个（判别串来源）= ${cats.length >= 9 ? cats[8].name : "（不足 9 个）"}');
      note('名字里有前缀吗 = ${cats.first.id.contains(':') ? "有（可疑）" : "没有（与插件源码一致）"}');
    }
  }

  // 列表侧的地面真值：证明「这个源不是整体坏了」
  var listTitles = <String>[];
  String? listError;
  try {
    final page = await SourinApi.getList(_provider, '');
    listTitles = page.items.map((it) => it.title).toList();
  } catch (e) {
    listError = e.toString();
  }
  if (listError != null) {
    say('getList 抛错 = $listError');
  } else {
    say('getList 返回 ${listTitles.length} 条: ${listTitles.join(" / ")}');
  }

  // ── ② 挂上**生产**的浏览页（生产 Navigator + 生产 MaterialPageRoute）──
  say('');
  say('──────── ② 打开生产浏览页 ────────');

  final shellEl = debugShellKey.currentContext;
  if (shellEl == null) {
    say('★ shell context 为 null ⇒ 中止');
    await finish(1);
  }
  // ★ 安全：上面刚判过 null 且为 null 时 `finish()` 返回 `Never`（已 exit），
  //   所以走到这里 `shellEl` 必然非空。lint 看不到 `Never` 的控制流。
  // ignore: use_build_context_synchronously
  final nav = Navigator.of(shellEl);
  /*
   * 与 `shell.dart:3769 _openBrowse` 构造的是**同一个路由、同一个页面**。
   * ★ categoryId 用默认空串（= 生产里 rank 分区传 '' 的那条路径），
   *   这样列表读数与 t366 已实测的 `get_list(360)` 逐字对齐；
   *   分类栏的渲染条件（`browse_page.dart:212`）只看 `_categories.isNotEmpty`
   *   与 `!_isRankMode`，**与 categoryId 无关** ⇒ 不影响被验证的命题。
   */
  nav.push(MaterialPageRoute<void>(
    builder: (_) => BrowsePage(
      provider: _provider,
      title: '浏览',
      isTv: Device.isTv,
    ),
  ));
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpFrame();

  // ★ 等的是**列表**不是分类栏 —— 否则旧臂会一直等到超时，
  //   读不到「页面活着但分类栏缺席」这个关键读数。
  //
  // ★★★ 期望条目必须**从本臂自己的 FFI 读数派生**，绝不写死。
  //   踩过的坑：首版写死 `'铁笼斗士'`（那是 t366 用
  //   `get_list(360, category_id:"1")` 得到的第 1 条），
  //   而本探针走的是 `categoryId: ''` ⇒ 上游返回的是**另一批** 20 条
  //   （无可替代 / 小姐不熙娣 / …）。列表其实画出来了，
  //   但探针找不到那个写死的串 ⇒ 误判 INSTRUMENT-FAILURE。
  //   写死期望值 = 把「上游对空分类返回什么」这个**外部变量**混进了判据。
  final expectItem = listTitles.isNotEmpty ? listTitles.first : '';
  if (expectItem.isEmpty) {
    say('★ FFI 没给出任何列表条目 ⇒ 无从判断列表是否渲染，中止');
    say('[T369] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }
  note('列表期望条目（取自 ① 的 FFI 读数）= "$expectItem"');

  final listUp = await waitUntil(
    () => findText(root, expectItem) != null,
    timeout: const Duration(seconds: 60),
    label: '浏览页列表',
  );
  /*
   * ★★★ 为什么用 `findText` 精确匹配，而**不是** `findTextContaining`：
   *   `poster_card.dart:469` 是 `Text(widget.title)`（完整标题），
   *   但同一张卡片的封面占位符 `:346-348` 画的是
   *   `widget.title.characters.first` —— **只有第一个字**。
   *   所以 `contains(标题)` 与 `== 标题` 在这棵树上**同真假**，
   *   两个都只有当完整标题渲染时才为真 —— 精确匹配更严，取它。
   *   ⚠️ 反过来，如果拿单个字当判据就会被占位符骗过（那是另一个串）。
   */
  ok('② 浏览页列表卡片真的渲染了（树里有 Text("$expectItem")）', listUp);
  ok('② 浏览页标题在（树里有 Text("浏览")）', findText(root, '浏览') != null);
  note('元素数 = ${elementCount(root)}');

  if (!listUp) {
    final s = await shoot('00-list-missing');
    note('失败现场 ${s.path} 颜色数=${s.colors}');
    say('★ 列表没渲染 ⇒ 两臂都无法比较，中止');
    say('[T369] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  await settleOverlays();
  final s = await shoot('01-browse');
  note('截图 ${s.path}  ${s.w}x${s.h}  采样颜色数=${s.colors}');
  ok('⓪ 截图非退化（>20 色）', s.colors > 20, '颜色数=${s.colors}');

  // ── ③ 元素树读数 ──────────────────────────────────────────────────────
  say('');
  say('──────── ③ 元素树：分类栏在不在 ────────');

  final texts = collectTexts(root);
  note('树里共 ${texts.length} 个不同的 Text.data');

  final hasDisc = texts.contains(_discriminator);
  final hasDiscNeg = texts.contains(_discriminatorNeg);
  final discEl = findText(root, _discriminator);

  say('判别串 "$_discriminator" 在树里 = $hasDisc');
  say('判别串的阴性对照 "$_discriminatorNeg" 在树里 = $hasDiscNeg');

  // ★ 阴性对照：证明 findText 真的会返回 null（否则"没找到"不可判）
  ok('③ findText 能返回 null（阴性对照串确实找不到）—— 仪器两个方向都灵敏',
      !hasDiscNeg && findText(root, _discriminatorNeg) == null);

  // 分类名普查：把 FFI 给的名单与树里的 Text 对照
  final rendered = cats.where((c) => texts.contains(c.name)).toList();
  say('FFI 给的 ${cats.length} 个分类里，树里出现了 ${rendered.length} 个'
      '（ListView 横向懒构建 ⇒ 只会有可见+缓存区内的那些）');
  if (rendered.isNotEmpty) {
    note('出现的分类 = ${rendered.map((c) => c.name).join(" / ")}');
  }

  // ── ④ 臂中立的不变量（A/B 的真正判据）────────────────────────────────
  say('');
  say('──────── ④ 不变量：UI 是否忠实反映 FFI ────────');

  ok('④ 树里有分类 ⟺ FFI 真的给了分类'
      '（hasCatsInTree=${rendered.isNotEmpty}  ffiGaveCats=${cats.isNotEmpty}）',
      rendered.isNotEmpty == cats.isNotEmpty);

  ok('④ 判别串在树里 ⟺ FFI 给了 $_expectCatCount 个分类'
      '（hasDisc=$hasDisc  ffiCount=${cats.length}）',
      hasDisc == (cats.length == _expectCatCount));

  // ★★★ 下面两条必须是**蕴含式**（`cats.isEmpty || …`），不能写成
  //   「FFI 分类数 == 51」这种无条件断言 —— 旧臂的预期行为就是
  //   **拿不到分类**（`插件报错: not a function`），无条件断言会让
  //   **对照组自己报红**，把「对照臂按预期工作」与「仪器坏了」混为一谈。
  //   蕴含式的语义：**只要 FFI 给了分类，它就必须恰好是 t366 实测的那批**，
  //   上游若漂移会在这里报出来，而不是静默换词。
  //   ⚠️ 旧臂上是**空真**（vacuous）—— 所以下面显式打出「本条为空真」，
  //   免得日后有人把空真当证据（#261 家族）。
  final countOk = cats.isEmpty || cats.length == _expectCatCount;
  ok('④ 若 FFI 给了分类，则数量必须是 t366 实测的 $_expectCatCount'
      '（FFI 分类数=${cats.length}）', countOk,
      cats.isEmpty ? '★ 本条在旧臂上为空真（FFI 没给分类）' : '');

  final ninthOk = cats.isEmpty || (cats.length >= 9 && cats[8].name == _discriminator);
  ok('④ 若 FFI 给了分类，第 9 个必须 == "$_discriminator"（判别串仍有效）', ninthOk,
      cats.isEmpty
          ? '★ 本条在旧臂上为空真'
          : (cats.length >= 9 ? '实际 "${cats[8].name}"' : '分类不足 9 个'));

  // ── ⑤ 光栅化：那一排胶囊真的画出来了吗 ───────────────────────────────
  say('');
  say('──────── ⑤ 光栅化（像素层）────────');

  final rect = globalRect(discEl);
  var nonBg = -1;
  if (rect == null) {
    note('判别串元素不存在 ⇒ 本臂无光栅化读数（旧臂预期如此）');
  } else {
    note('判别串元素全局矩形 = ${rect.left.toStringAsFixed(1)},'
        '${rect.top.toStringAsFixed(1)}  ${rect.width.toStringAsFixed(1)}x'
        '${rect.height.toStringAsFixed(1)}');
    final cy = rect.center.dy.round().clamp(0, s.h - 1);
    // ★ 参照底色取自**同一行** x=4：分类栏 ListView 的 padding 是 24，
    //   所以 x=4 一定在胶囊之外、就是页面底色本身。
    final bg = s.px(4, cy);
    note('页面底色参照 (4,$cy) = ${hex(bg)} ${rgbOf(bg)}');
    nonBg = nonBgIn(s, rect, bg);
    note('判别串矩形内非底色像素 = $nonBg / ${(rect.width * rect.height).round()}');
    say('');
    say('该行 (y=$cy) 游程编码：');
    for (final seg in rowRle(s, cy)) {
      note(seg);
    }
  }
  ok('⑤ 判别串元素真的被光栅化了（矩形内有非底色像素）—— 无元素时跳过',
      rect == null || nonBg > 0, '非底色像素=$nonBg');

  // ── ⑥ 判词 ────────────────────────────────────────────────────────────
  say('');
  final verdict = hasDisc ? 'CATBAR-PRESENT' : 'CATBAR-ABSENT';
  say('判词: tag=$_tag  DLL身份见 ⓪  '
      'FFI分类数=${cats.length}  树里分类数=${rendered.length}  '
      '判别串=$hasDisc  ⇒ $verdict');
  say('[T369] RESULT tag=$_tag verdict=$verdict ffiCats=${cats.length} '
      'treeCats=${rendered.length} pass=$pass fail=$fail');
  await finish(fail == 0 ? 0 : 1);
}
