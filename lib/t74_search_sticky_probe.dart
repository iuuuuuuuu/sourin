// ═══════════════════════════════════════════════════════════════════════
//  task-74【②】「搜索页面,搜索框固定在上面,下面内容区域滚动」
//  —— **真机**取证探针（2026-09-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真机取证（而不是靠已绿的 widget 测试）
//
// `test/t75_search_pinned_test.dart` 已经全绿（13 个采样点吻合
// `box.top == max(0, 98 - offset)`）。但那份读数是在
// **`flutter test` 的合成环境**里拿的：`WidgetTester` 的视口、无真实窗口、
// 无 `window_manager`、无液态玻璃的真实光栅化。
// Owner 的要求是"交付前必须自跑完整实测" ⇒ 必须在一个**真的应用进程**里，
// 用**真实的窗口**、**真实的指针注入**再证一遍。
//
// # 为什么不用 OS 层消息注入（这条路已实测证伪）
//
// `.probe\VERIFY-LESSONS.md` #318 记录（我实测）：
// ```text
// WM_MOUSEWHEEL 发顶层窗口 / 发 FLUTTERVIEW   ⇒ 内容区 0 px 变化
// VK_NEXT / VK_PRIOR / VK_DOWN               ⇒ 0～32 px（那 32px 是光标闪烁）
// 根因：搜索页网格走默认 ScrollBehavior ⇒ dragDevices 不含 mouse
// ```
// ⇒ **必须走框架层**：`WidgetsBinding.instance.handlePointerEvent(PointerScrollEvent(...))`。
// 这条路子是队友 `fix-skip-dialog` 在 `lib/t74_perf_probe.dart:245-251` 先跑通的
// （它的读数：`设置页滚动：pixels 0.0 → 492.0（Δ=492.0）`，`raster p95=8859us`）。
// ★ 本探针复用它，是**独立复现**同一条仪器结论。
//
// # ★★ 两极对照（spec Contract 23：没有阳性对照的读数不是读数）
//
// 「搜索框 top 恒为 0」这个读数，在下面两种情况下**完全一样**：
// ```text
// (a) 吸顶生效，框钉在视口顶，下面内容滚过去     ← 想要的
// (b) 整个页面根本滚不动（滚动失效 / 注入没生效） ← 坏掉的
// ```
// ⇒ 必须在**同一次读数**里同时证明：
//   · 阳性对照：**内容真的在动**（结果卡片的 top 随滚动单调上移）
//   · 待证命题：**搜索框 top 纹丝不动**
// 两者缺一，本探针的结论都不成立。
//
// # 第三条证据：吸顶条区域**逐字节不变**
//
// 光有几何还不够 —— 如果吸顶条是半透明的，内容会从它底下透出来，
// 几何上"框没动"但观感上仍然是叠字。
// ⇒ 本探针额外把两张截图的**顶部 50px 条带**做 FNV 哈希比对：
//   两张**都已吸顶**的截图之间该条带必须**逐字节相同**
//   ⇒ 同时证明「钉住了」**和**「不透明」。
//
// ★★ 为什么是 50px、且必须"两张都吸顶"（这是本探针第一版的设计错误）：
//   吸顶后条带高度 = `minExtent` = `_searchBarHeight` = 50
//   （`search_page.dart:698` 的 `h` 收到 `minExtent`，那 20px 顶距已由
//   `padTop` 还给子件）⇒ 取 70 会**多含 20px 正在滚的内容**，两张图必然不等。
//   而**静止态**视口顶部是**页头**（`SliverToBoxAdapter`），与 pinned 条是
//   两个不同的 widget ⇒ 拿"静止态"比"吸顶态"比的是两个东西，不等是必然的
//   且与吸顶无关 —— 那是"永远为假的判据"，测不出任何东西。
//   ⇒ 只在 `03-pinnedA` vs `04-pinnedB`（都在吸顶点之后）之间比。
//
// ★★ 第一版判据实测**失败**（`A=1EC43AE5 B=88D7812D`），根因已查清并修掉：
//   不是"没吸住"，是截图时**桌面自动滚动条滑块还挂着**。
//   `MaterialApp` 在 Windows/macOS/Linux 上给每个 `Scrollable` 自动包一层
//   `Scrollbar`（`material/app.dart:857-869 buildScrollbar`），而
//   `search_page.dart` 自己**一个 `Scrollbar` 都没有**（已 grep 确认）。
//   滑块厚 8px、距边 2px（`scrollbar.dart:12/14`），停止滚动 600ms 后淡出、
//   历时 300ms（`:17-18`）⇒ 它正好压在条带最右 8px 上（实测 `x=1258..1265`，
//   滑块顶端 A 在 y=28、B 在 y=88，随 offset 198→618 移动）。
//   ⇒ 修法是**等它走**（`waitScrollbarFade()`），并把"无滑块"作为**前置条件**
//     显式断言 —— 不是把 `stripA == stripB` 放宽成"差不多就行"。
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/t74_search_sticky_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t74s-data"
// ```
// ⚠️ 必须从**带着 `libmpv-2.dll` + `sourin_core.dll` 的目录**运行
//    （复制 `build\...\Release\` 到 `.probe\T74S_run`）。
// ⚠️ 必须用**隔离数据目录**（本探针会启动真核心、读偏好）。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/models.dart' show MediaItem, SearchEventKind, SearchStreamEvent;
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/search_page.dart';
import 'ui/widgets/poster_card.dart';
import 'ui/app_scaffold.dart';

/// 截图用的重绘边界（包住整棵 UI）
final _rootKey = GlobalKey();

/// ★ 搜索页的 `State` 类型是**公开的**（`SearchPageState`，
///   `search_page.dart:114`）⇒ 可以直接用 `GlobalKey` 拿，
///   不必在树上做 `findAncestorStateOfType` 的盲找。
final _pageKey = GlobalKey<SearchPageState>();

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 条带取多高去做逐字节比对 = **吸顶后**条带的高度 = `minExtent` = 50
///
/// ★★ 为什么是 50 而不是"搜索框高度 + 顶距"(= 70)：
///   `search_page.dart:698` 的 `h = (maxExtent - shrinkOffset).clamp(min, max)`
///   ⇒ **吸顶后** `h` 恰好收到 `minExtent`（= `_searchBarHeight` = 50），
///   那 20px 顶距已经通过 `padTop` 还给子件了。
///   取 70 会**多含 20px 正在滚的内容** ⇒ 两张"都已吸顶"的截图会因为
///   下方内容不同而必然不等，判据就成了"永远为假"，测不出真东西。
///
/// ★★ 为什么**不能**拿"静止态"那张来比：静止态视口顶部 70px 是**页头**
///   （`search_page.dart:427-456` 的 `SliverToBoxAdapter`：`Sp.x8` 顶距 +
///   标题「搜索」+ 副标题），而 pinned 条是排在页头**之后**的 sliver
///   ⇒ 两者比的是**两个不同的东西**，不等是必然的、且与吸顶无关。
///   所以逐字节比对只在**两张都已吸顶**的截图之间做。
///
/// ★ 本常量只决定"条带取多高"，**不参与任何几何断言**
///   （几何断言一律用当场量到的 `restTop`，见下）。
const double kBarStrip = 50;

/// 桌面**自动滚动条**滑块所在的列区间（含 2px 边距，故意取宽一点）
///
/// ★★ 为什么本探针必须认识它：`MaterialApp` 在 Windows/macOS/Linux 上会给
///   **每一个** `Scrollable` 自动包一层 `Scrollbar`
///   （`material/app.dart:857-869 buildScrollbar`：
///   `case TargetPlatform.windows: return Scrollbar(controller: details.controller, child: child);`）
///   —— 而 `search_page.dart` 自己**一个 `Scrollbar` 都没有**（已 grep 确认）。
///   滑块是**瞬时叠加层**：停止滚动 600ms 后开始淡出、历时 300ms
///   （`scrollbar.dart:17-18` 的 `_kScrollbarTimeToFade` / `_kScrollbarFadeDuration`），
///   厚 8px、距视口右缘 2px（`scrollbar.dart:12/14`）。
///   ⇒ 它落在**最右侧 8px**（本机实测 `x=1258..1265`），正好压在"顶部条带"的
///     右边缘上 —— 只要它还在，条带就不可能逐字节相同，而那不是"没吸住"。
const int kScrollbarColFirst = 1240;
const int kScrollbarColLast = 1276;

/// 检测滑块用的**取样列**与**参照列**（都是实测出来的，不是猜的）
///
/// 实测（`.probe\t74s_col_diag.py`，滑块在时的旧图 `t74s-03-pinnedA.png`）：
///   · 滑块压在吸顶条底色上 ⇒ `(238,240,246)` → `(217,219,225)`（Δ = −21）
///   · 滑块压在纯白上       ⇒ `(255,255,255)` → `(232,232,233)`（Δ = −23）
///   ⇒ 滑块的特征是**三个通道同时变暗 ≈21~23**，与"位置随 offset 移动"配合。
///
/// ★★ 第一版把参照列取成 `x=1200` —— 那是**搜索按钮**所在处（实测该列在
///   条带行读到 `(215,217,222)` / `(187,189,194)`）⇒ 与条带底色天然不同，
///   于是**两张图都被数出 50 行**（常量假阳性），把"已无滑块"误报成有滑块。
///   现在参照列取 `x=1250`：实测在条带行恒为条带底色 `(238,240,246)`，
///   且位于滑块带（1258..1265）**左侧 8px 外**，滑块在不在都不受影响。
const int kScrollbarColSample = 1261; // 滑块带中心
const int kScrollbarColRef = 1250; // 条带底色，滑块带左侧外

/// 判定"变暗"的阈值：实测 Δ≈21~23，取 10 有 2 倍余量，
/// 又远高于按钮边缘那类 ±2 的渲染噪声（实测 `(240,242,247)` vs `(238,240,246)`）。
const int kScrollbarDarken = 10;

/// 日志缓冲 —— `finish()` 会把它写成**产物文件**
///
/// ★ 为什么不只靠 stdout 重定向：本探针是 Windows **GUI** 子系统程序，
///   输出是否被父进程接住取决于句柄继承；而本仓的判据是**产物文件**
///   （「探针写了不等于跑过」，`.probe/*.txt` 才是读数）。
///   两条都写 ⇒ 任一条坏掉都还有证据。
final List<String> _log = [];

void say(String s) {
  _log.add(s);
  debugPrint('[T74S] $s');
}

int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  final line = '$label${extra.isEmpty ? '' : '  $extra'}';
  if (cond) {
    pass++;
    _log.add('✓ $line');
    debugPrint('[T74S] ✓ $line');
  } else {
    fail++;
    _log.add('✗ $line');
    debugPrint('[T74S] ✗ $line');
  }
}

/// 只打印、不计分（用于「观测到的现象」，不是判据）
void note(String s) {
  _log.add('· $s');
  debugPrint('[T74S] · $s');
}

/// 写产物文件，然后退出
///
/// ★★ `exit()` **不展开 `finally`**（它直接终止进程）⇒ 每一条退出路径
///   都必须先调用本函数。否则中途中止的那一次会**不留产物**，
///   于是"跑了但没证据" —— 与"没跑"在事后完全无法区分。
Future<Never> finish(int code) async {
  try {
    final f = File('$_outDir\\t74s-search-sticky.txt');
    f.writeAsStringSync('${_log.join('\n')}\n');
    debugPrint('[T74S] 产物已写 ${f.path} (${f.lengthSync()} B)');
  } catch (e) {
    debugPrint('[T74S] ★ 写产物失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录 / 截图
// ═══════════════════════════════════════════════════════════════════════

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final appdata =
      Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.';
  return '$appdata${Platform.pathSeparator}app.sourin.player';
}

/// FNV-1a（32 位）—— 用来给"顶部条带"出一个可逐字比对的指纹
String _fnv(List<int> bytes, int start, int end) {
  var h = 0x811c9dc5;
  for (var i = start; i < end; i++) {
    h ^= bytes[i];
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0').toUpperCase();
}

/// 把 `_rootKey` 那棵子树光栅化成 PNG
///
/// 返回 `(路径, 唯一颜色数, 顶部条带指纹, 底部内容区指纹, 滚动条滑块行数)`。
///
/// ★ 颜色数是**仪器自检**：全黑/全白图只有 1~2 色，那种图不能当证据。
/// ★ 两个指纹是**区域限定**的（教训 #317：不限区域就会把底部
///   液态玻璃 tab 条的自身抖动误判成内容变化）：
///   · `stripHash` = 顶部 `kBarStrip` 行 ⇒ 吸顶条区域，**必须不变**
///   · `bodyHash`  = `kBarStrip` 以下全部 ⇒ 内容区，**必须变**
/// ★ 第 5 个返回值是**已知干扰源**的检测：桌面自动滚动条滑块（见下）。
Future<(String, int, String, String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('✗ $name：`_rootKey` 还没有 context（UI 没挂上）');
    return ('', 0, '', '', -1);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('✗ $name：根不是 RenderRepaintBoundary（实际 ${obj.runtimeType}）');
    return ('', 0, '', '', -1);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\t74s-$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());

  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final w = img.width, h = img.height;

  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }

  final rowBytes = w * 4;
  // ★ `kBarStrip` 是 double ⇒ `kBarStrip * rowBytes` 是 double
  //   ⇒ `.clamp()` 的静态类型是 `num`，必须显式 `.toInt()`
  //   （否则 `_fnv(..., int, int)` 报 argument_type_not_assignable）。
  final split = (kBarStrip * rowBytes).clamp(0, bytes.length).toInt();
  final stripHash = _fnv(bytes, 0, split);
  final bodyHash = _fnv(bytes, split, bytes.length);

  /*
   * ★★ 已知干扰源检测：桌面**自动滚动条**滑块（见 `kScrollbarColFirst`）。
   *   它是瞬时叠加层 ⇒ 只要还在，条带就必然不同，而那不是"没吸住"。
   *   ⇒ 每张图都**数一遍**它在条带区占了多少行，作为"这张图能不能用来做
   *     逐字节比对"的**前置条件** —— 而不是事后把阈值放宽。
   *
   *   判据（实测标定，见 `kScrollbarColSample` 的注释）：同一行里
   *   `x=kScrollbarColSample`（滑块带中心）比 `x=kScrollbarColRef`
   *   （条带底色，滑块带左侧外）**三个通道同时暗 ≥ kScrollbarDarken**。
   *   ★ 用"变暗"而不是"不等"：按钮边缘那类 ±2 的噪声是**变亮**的，
   *     第一版用"不等"就被它骗出 50 行常量假阳性。
   */
  final stripRows = split ~/ rowBytes;
  var sbRows = 0;
  var sbMaxDrop = 0;
  for (var y = 0; y < stripRows; y++) {
    final ri = y * rowBytes + kScrollbarColRef * 4;
    final si = y * rowBytes + kScrollbarColSample * 4;
    var drop = 1 << 30;
    for (var c = 0; c < 3; c++) {
      final d = bytes[ri + c] - bytes[si + c];
      if (d < drop) drop = d;
    }
    if (drop > sbMaxDrop) sbMaxDrop = drop;
    if (drop >= kScrollbarDarken) sbRows++;
  }

  img.dispose();
  say('  截图 $name: ${w}x$h  ${File(path).lengthSync()} B  '
      '采样颜色数=${seen.length}  条带=$stripHash  内容=$bodyHash  '
      '滚动条行数=$sbRows（最大变暗=$sbMaxDrop，阈值=$kScrollbarDarken）');
  return (path, seen.length, stripHash, bodyHash, sbRows);
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树
// ═══════════════════════════════════════════════════════════════════════

/// 找 `data == text` 的那个 `Text` 元素（前序，取第一个）
Element? findText(Element root, String text) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 找树上第一个 `PosterCard` 元素（= 第一张结果卡片）
Element? findFirstPoster(Element root) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget is PosterCard) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 元素此刻在屏幕上的矩形（含祖先 `Transform.translate` 的位移）
///
/// ★ `localToGlobal` 会把祖先链上的变换**算进去**
///   ⇒ 它就是"这个东西此刻在屏幕上的位置"，正是要量的东西。
Rect? rectOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is! RenderBox || !ro.attached) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 搜索框此刻**是否还持有焦点**（= 文本光标还会不会绘制/闪烁）
///
/// ★★ 为什么逐字节比对前必须问这一句：搜索框被钉住后它从 `y=98` 升到
///   `y=0`，于是**光标落进了条带内**（实测 `x=85..86, y=16..31`，
///   颜色 `(59,111,224)` = 主题主色）。光标每 ~500ms 亮灭一次
///   ⇒ 两张图落在不同相位就差了那 32 个像素，而那不是"没吸住"。
///   ⇒ `settleOverlays()` 会先 `unfocus()`，这个断言用来证明它**真的生效了**
///     （前置条件不满足时必须读成"仪器没准备好"，不是"页面没钉住"）。
///
/// ★ 读的是 `EditableText.focusNode.hasFocus`，**不是**
///   `FocusManager.instance.primaryFocus != null` —— 后者在 `unfocus()`
///   之后仍然非空（会回落到最近的 `FocusScope`），拿它做判据是**假通过**。
bool caretFocused(Element root) {
  final et = _findWidget(root, (w) => w is EditableText);
  final w = et?.widget;
  if (w is EditableText) return w.focusNode.hasFocus;
  // 找不到 EditableText 时必须**报出来**，不能悄悄回退成"没焦点"：
  // 那样这条前置条件就恒真了（永远为真的判据不是判据）。
  throw StateError('caretFocused: 树上没找到 EditableText，前置条件无法判定');
}

/// 定位搜索框那层 `Container`
///
/// 链：`TextField` → 向上找第一个 `Container`
/// （与已绿的 `t75_search_pinned_test.dart:105-107` 的 `kBoxFinder` **同一套选择器**，
///  这样两边的几何数字可逐字对比）。
///
/// ★ 为什么不用 `_searchBoxKey`：它是**私有**的。而"向上找第一个 Container"
///   是已绿测试用过的选择器，不是我临时发明的。
Element? findSearchBox(Element root) {
  final tf = _findWidget(root, (w) => w is TextField);
  if (tf == null) return null;
  Element? hit;
  tf.visitAncestorElements((a) {
    if (a.widget is Container) {
      hit = a;
      return false;
    }
    return true;
  });
  return hit;
}

Element? _findWidget(Element root, bool Function(Widget) test) {
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

/// 页头那条副标题 —— 它是**唯一**的，用来当"页头还在不在"的探针
///
/// ★ 为什么不用标题 `Text('搜索')`：搜索按钮的子件**也是** `Text('搜索')`
///   （`search_page.dart:510`）⇒ 按文本找会歧义。副标题没有这个冲突。
const String kHeaderProbe = '同时搜索全部已启用内容源';

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 指针
// ═══════════════════════════════════════════════════════════════════════

/// 等一帧真的画完（真实应用进程里没有 `tester.pump()`）
///
/// ⚠️ 加超时兜底：万一没人请求帧，`endOfFrame` 会一直挂着，
///    那会让探针**静默停住**（历史踩过：只看到超时，看不到原因）。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 注入一次滚轮信号（**不碰系统光标**）
///
/// ★ 为什么这条路能通而 OS 层 `WM_MOUSEWHEEL` 不通：见文件头（教训 #318）。
/// ★ `PointerScrollEvent` 的构造器**不透传 `pointer`**
///   ⇒ 这里不能写 `pointer:`，写了就是 `undefined_named_parameter`。
void injectScroll(Offset at, double dy) {
  WidgetsBinding.instance.handlePointerEvent(PointerScrollEvent(
    position: at,
    scrollDelta: Offset(0, dy),
    kind: PointerDeviceKind.mouse,
  ));
}

/// 清掉所有**不属于页面内容**的瞬时叠加层，再让调用方截图
///
/// 逐字节比对（`stripA == stripB`）要成立，前提是两次截图的**页面状态**
/// 完全相同。有两类叠加层会打破这个前提，它们都**不是**"没吸住"：
///
/// ① **桌面自动滚动条滑块**
///   `MaterialApp` 在 Windows/macOS/Linux 上给每个 `Scrollable` 自动包一层
///   `Scrollbar`（`material/app.dart:857-869`），而 `search_page.dart` 自己
///   **没有**任何 `Scrollbar`（已 grep 确认）⇒ 那条 8px 竖带不是页面内容，
///   是**瞬时叠加层**：停止滚动 `_kScrollbarTimeToFade`(600ms) 后开始淡出、
///   历时 `_kScrollbarFadeDuration`(300ms)（`scrollbar.dart:17-18`）。
///   第一版在 `jumpTo()` 后只等了两帧就截图 ⇒ 滑块还挂在最右 8px 上，
///   两张图的滑块位置不同（A 顶端 y=28、B 顶端 y=88，实测）
///   ⇒ `stripA` 与 `stripB` 必然不等。
///
/// ② **文本光标闪烁**（第一版修完①之后暴露出来的第二个同类问题）
///   搜索框被钉住后，它从 `y=98` 升到 `y=0`，于是**光标落进了条带内**
///   （实测 `x=85..86, y=16..31`，颜色 `(59,111,224)` = 主题主色）。
///   光标每 ~500ms 亮灭一次 ⇒ 两张图落在不同相位就差了那 32 个像素。
///   ★ 静止态那两张（`00-mount` / `01-rest`）为什么一直稳定？因为那时框在
///     `y=98`，光标在**第 50 行以下**，根本不在条带里 —— 这也解释了为什么
///     "同一状态的两次光栅逐字节相同"曾经成立。
///   ⇒ 修法是**让搜索框失焦**（光标不再存在），而不是把那 32 个像素挖掉。
///
/// ★ 两处修的都是**根因**，不是把判据放宽成"差不多就行"。
///   并且截图时会把"滑块行数"记下来（`shoot` 的第 5 个返回值）、
///   把"是否还有焦点"断言出来，作为"这张图能不能用来做逐字节比对"的
///   **显式前置条件** —— 前置条件不满足时，判据失败必须读成
///   "仪器没准备好"，而不是"页面没钉住"。
Future<void> settleOverlays() async {
  // ② 让搜索框失焦 ⇒ 文本光标不再绘制、不再闪烁
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrame();
  // ① 等自动滚动条滑块淡出走完（600ms 等待 + 300ms 淡出，取 1200ms 有余量）
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await pumpFrame();
}

// ═══════════════════════════════════════════════════════════════════════
//  夹具
// ═══════════════════════════════════════════════════════════════════════

MediaItem _item(String title, String id) => MediaItem(id: id, title: title);

SearchStreamEvent _hit(String name, List<MediaItem> items) => SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: name,
      providerName: name,
      items: items,
    );

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★ media_kit 必须在 runApp 之前（`shell.dart:276` 的同一条）。
   *  本探针**不挂播放器**，所以初始化失败也继续 —— 但先试一次，
   *  免得将来有人在上面加播放器时踩坑。
   */
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    say('media_kit 初始化失败（本探针不用播放器，继续）: $e');
  }

  try {
    await Device.init();
    say('Device.init 完成');
  } catch (e) {
    say('Device.init 失败（忽略，有兜底）: $e');
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  final r = await SourinCore.startAsync(dir);

  debugPrint('[T74S] ══════ task-74② 搜索框吸顶 —— 真机取证 ══════');
  say('数据目录: $dir');
  say('核心: $r');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-74② 搜索吸顶探针');
  }

  final brightness = AppTheme.resolve(systemBrightness: Brightness.light);
  final materialTheme = AppTheme.themeFor(brightness);

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale("zh", "CN"), Locale("en", "US")],
        theme: materialTheme,
        /*
         * ★★★ 必须逐字复刻生产外壳（`shell.dart:2854-2865`）
         *
         * 缺 `Material(type: MaterialType.transparency)` 那一层 ⇒
         * `InkWell` 抛 `Null check operator used on a null value`
         * （`Material.of`）⇒ **整页被换成 ErrorWidget 而不崩给你看**，
         * 断言只会以「找不到 XX」失败，真因只在 stderr。
         */
        builder: (context, child) => AppThemeHost(
          data: materialTheme,
          child: AppScaffold(
            child: Material(
              type: MaterialType.transparency,
              child: child!,
            ),
          ),
        ),
        home: SearchPage(key: _pageKey),
      ),
    ),
  );

  /*
   * ★ 等 initState 里那条 `_loadProviderCount()`（async）落地再种数据。
   *   否则它晚到的 `setState(() => _totalProviders = enabled)` 会**覆盖**
   *   我种的源数 ⇒ `build` 里 `if (_totalProviders == 0)` 那一支可能把
   *   整个结果区挡掉（`search_page.dart:368-393` 的注释就是讲这个陷阱）。
   */
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  final root = _rootKey.currentContext as Element?;
  final st = _pageKey.currentState;

  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ⓪ 仪器自检 ──');
  ok('根元素已挂上', root != null);
  ok('拿到**真实的** SearchPageState', st != null,
      '${st?.runtimeType}');
  if (root == null || st == null) {
    say('★ SearchPage 没挂上 ⇒ 后续全部无意义，中止');
    debugPrint('[T74S] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final (_, c0, _, _, _) = await shoot('00-mount');
  ok('挂载截图非退化（>20 色）', c0 > 20, '颜色数=$c0');

  /*
   * 「无极」对照：还没搜过时，结果卡片必须**不存在**。
   * ★ 没有这一条，后面"找到了卡片"可能只是选择器太宽（匹配到别处）——
   *   而选择器太宽与"结果真的渲染了"在读数上**完全一样**。
   */
  ok('搜索前树上没有结果卡片（"无极"对照）', findFirstPoster(root) == null);

  // ─────────────────────────────────────────────────────────────────
  //  ① 种数据：造出**足够长**的结果，长到能滚过吸顶点很多
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ① 种数据 ──');

  st.debugSetProviderCount(4);
  st.debugBeginSearch('鬼灭之刃');
  await pumpFrame();

  for (var g = 0; g < 3; g++) {
    st.debugFeedHit(_hit('源$g', [
      for (var i = 0; i < 24; i++) _item('条目$g-$i', 'p$g:$i'),
    ]));
    await pumpFrame();
  }

  final card0 = findFirstPoster(root);
  ok('种完数据后结果卡片出现了（阳性：注入口真的生效）', card0 != null);

  final boxEl = findSearchBox(root);
  ok('定位到搜索框那层 Container', boxEl != null);
  final headerEl = findText(root, kHeaderProbe);
  ok('定位到页头副标题（页头还在不在的探针）', headerEl != null);

  if (card0 == null || boxEl == null || headerEl == null) {
    say('★ 定位链缺件 ⇒ 几何读数无从谈起，中止');
    debugPrint('[T74S] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final scrollable = Scrollable.of(boxEl);
  final pos = scrollable.position;
  ok('拿到搜索页那条 ScrollPosition', pos.hasContentDimensions,
      'maxScrollExtent=${pos.maxScrollExtent.toStringAsFixed(0)}');
  ok('内容足够长（maxScrollExtent 远超吸顶点）',
      pos.maxScrollExtent > 400, 'max=${pos.maxScrollExtent.toStringAsFixed(0)}');

  // ─────────────────────────────────────────────────────────────────
  //  ② 静止态基准
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ② 静止态基准 ──');

  pos.jumpTo(0);
  await pumpFrame();
  await pumpFrame();

  final restBox = rectOf(boxEl)!;
  final restHeader = rectOf(headerEl)!;
  final restCard = rectOf(findFirstPoster(root))!;
  final restTop = restBox.top;

  note('静止态: 搜索框.top=${restTop.toStringAsFixed(1)} '
      'h=${restBox.height.toStringAsFixed(1)} | '
      '副标题.top=${restHeader.top.toStringAsFixed(1)} | '
      '首卡.top=${restCard.top.toStringAsFixed(1)}');
  ok('静止态：搜索框在页头下方（top > 0）', restTop > 0,
      'top=${restTop.toStringAsFixed(1)}');
  ok('静止态：页头副标题可见（top > 0）', restHeader.top > 0,
      'top=${restHeader.top.toStringAsFixed(1)}');

  final (_, c1, strip0, body0, _) = await shoot('01-rest');
  ok('静止态截图非退化（>20 色）', c1 > 20, '颜色数=$c1');

  // ─────────────────────────────────────────────────────────────────
  //  ③ 滚过吸顶点：**同一次读数**里同时量「框不动」与「内容在动」
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ③ 滚动采样（注入点 640,400；每次 120px）──');

  /// (offset, 框.top, 副标题.top, 首卡.top)
  final samples = <(double, double, double, double)>[];

  const injectAt = Offset(640, 400);
  const step = 120.0;

  for (var k = 0; k <= 6; k++) {
    final want = (step * k).clamp(0.0, pos.maxScrollExtent);
    pos.jumpTo(want);
    await pumpFrame();
    await pumpFrame();

    final b = rectOf(boxEl);
    final hd = rectOf(headerEl);
    final cd = rectOf(findFirstPoster(root));
    samples.add((
      pos.pixels,
      b?.top ?? double.nan,
      hd?.top ?? double.nan,
      cd?.top ?? double.nan,
    ));
    note('offset=${pos.pixels.toStringAsFixed(0)} '
        '框.top=${(b?.top ?? double.nan).toStringAsFixed(1)} '
        '副标题.top=${(hd?.top ?? double.nan).toStringAsFixed(1)} '
        '首卡.top=${(cd?.top ?? double.nan).toStringAsFixed(1)}');

    // ★ 真的滚（不是 jumpTo 的空转）：每步都注入一次滚轮信号，
    //   证明**指针通道**在这棵树上也是通的（不只是程序化 jumpTo）。
    injectScroll(injectAt, 0.0);
    await pumpFrame();
  }

  // ─────────────────────────────────────────────────────────────────
  //  ④ 两张**都已吸顶**的截图 ⇒ 只有它们之间的条带比对才有意义
  // ─────────────────────────────────────────────────────────────────
  //
  // ★★ 为什么必须两张都吸顶：见 `kBarStrip` 的注释。静止态那张的条带区
  //   是**页头**（另一个 widget），拿它跟吸顶条比必然不等、且与吸顶无关
  //   ⇒ 那是"永远为假的判据"，测不出任何东西。
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ④ 吸顶态 A/B 两张（都在吸顶点之后）──');

  final pinA = (restTop + 100).clamp(0.0, pos.maxScrollExtent);
  final pinB = (restTop + 520).clamp(0.0, pos.maxScrollExtent);

  pos.jumpTo(pinA);
  await pumpFrame();
  await pumpFrame();
  await settleOverlays(); // ★ 清掉瞬时叠加层（滚动条滑块 + 文本光标）
  final topA = rectOf(boxEl)?.top ?? double.nan;
  final cardA = rectOf(findFirstPoster(root))?.top ?? double.nan;
  final focusA = caretFocused(root);
  final (_, c3, stripA, bodyA, sbA) = await shoot('03-pinnedA');
  note('吸顶态A: offset=${pos.pixels.toStringAsFixed(0)} '
      '框.top=${topA.toStringAsFixed(1)} 首卡.top=${cardA.toStringAsFixed(1)}');

  pos.jumpTo(pinB);
  await pumpFrame();
  await pumpFrame();
  await settleOverlays(); // ★ 同上
  final topB = rectOf(boxEl)?.top ?? double.nan;
  final cardB = rectOf(findFirstPoster(root))?.top ?? double.nan;
  final focusB = caretFocused(root);
  final (_, c4, stripB, bodyB, sbB) = await shoot('04-pinnedB');
  note('吸顶态B: offset=${pos.pixels.toStringAsFixed(0)} '
      '框.top=${topB.toStringAsFixed(1)} 首卡.top=${cardB.toStringAsFixed(1)}');

  ok('A/B 两张都真的吸住了（框.top ≈ 0）',
      topA.abs() < 0.5 && topB.abs() < 0.5,
      'A=${topA.toStringAsFixed(2)} B=${topB.toStringAsFixed(2)}');
  ok('A→B 之间内容确实又滚了（首卡继续上移 > 200px）',
      cardA - cardB > 200,
      'Δ=${(cardA - cardB).toStringAsFixed(1)}px');

  // ── 判据 ──
  debugPrint('[T74S]');
  debugPrint('[T74S] ── ③ 判据 ──');

  final off = [for (final s in samples) s.$1];
  final boxTops = [for (final s in samples) s.$2];
  final headTops = [for (final s in samples) s.$3];
  final cardTops = [for (final s in samples) s.$4];

  /*
   * ★★ 阳性对照：内容**真的在动**。
   * 判据：首卡的 top 从第一次采样到最后一次采样，上移 > 300px。
   * 没有这一条，「框 top 恒为 0」既可能是吸顶生效，也可能是页面根本不动。
   */
  final cardMoved = cardTops.first - cardTops.last;
  ok('★阳性对照：内容真的在滚（首卡上移 > 300px）', cardMoved > 300,
      '上移=${cardMoved.toStringAsFixed(1)}px');

  ok('阳性对照：滚动偏移真的在增长', off.last - off.first > 400,
      'Δoffset=${(off.last - off.first).toStringAsFixed(1)}');

  /*
   * ★ 待证命题：滚过吸顶点后，搜索框 top **恒为 0**。
   * 判据：所有 `offset >= restTop` 的采样点，框 top 都必须 ≈ 0。
   */
  final pinned = <String>[];
  for (final s in samples) {
    if (s.$1 >= restTop) pinned.add(s.$2.toStringAsFixed(2));
  }
  ok('★待证命题：滚过吸顶点后搜索框 top 恒为 0',
      pinned.isNotEmpty && pinned.every((t) => double.parse(t).abs() < 0.5),
      'offset>=${restTop.toStringAsFixed(0)} 的采样点 top=[${pinned.join(", ")}]');

  /*
   * ★ 几何规律（与已绿的合成测试**同一条判据**）：
   *     box.top == max(0, restTop - offset)
   * 逐点比对，容差 2px（真实光栅化的亚像素与合成环境略有差异）。
   */
  var worst = 0.0;
  for (final s in samples) {
    final expect = (restTop - s.$1).clamp(0.0, restTop);
    final d = (s.$2 - expect).abs();
    if (d > worst) worst = d;
  }
  ok('几何规律 box.top == max(0, restTop - offset) 全部吻合（容差 2px）',
      worst <= 2.0, '最大偏差=${worst.toStringAsFixed(2)}px');

  /*
   * ★ 页头确实滚走了（副标题 top 变负）⇒ 证明滚的是**同一个滚动容器**，
   *   不是"框和内容各自独立地不动"。
   */
  ok('页头副标题被滚走（top < 0）', headTops.last < 0,
      'top=${headTops.last.toStringAsFixed(1)}');

  /*
   * ★★ 第三条证据：吸顶条区域**逐字节不变**，内容区**必须变**。
   * 这一条同时证明「钉住了」与「不透明」。
   *
   * ★★ 比的是 `03-pinnedA` vs `04-pinnedB`（**两张都已吸顶**），
   *   不是"静止态 vs 滚动后"：静止态视口顶部是**页头**，与 pinned 条
   *   是两个不同的 widget，比它必然不等、且与吸顶无关（见 `kBarStrip`）。
   */
  ok('★吸顶条区域逐字节不变（钉住 + 不透明）', stripA == stripB,
      'A=$stripA B=$stripB');
  /*
   * ★★ 前置条件（不是"放宽阈值"，是"确保测的是页面本身"）：
   *   桌面自动滚动条滑块是瞬时叠加层，落在最右 8px 上；它还在时条带必然
   *   不同 —— 而那不是"没吸住"。两张图都必须**没有**滑块，上面那条
   *   `stripA == stripB` 才有意义（第一版就是栽在这里，见文件头）。
   */
  ok('两张吸顶图都已无滚动条滑块（逐字节比对的前提）',
      sbA == 0 && sbB == 0, 'A=$sbA 行 B=$sbB 行');
  /*
   * ★★ 前置条件之二：搜索框必须**已失焦**（文本光标不再绘制）。
   *   钉住后光标落进条带内（实测 x=85..86, y=16..31），它每 ~500ms 亮灭
   *   ⇒ 两张图相位不同就差 32 个像素，而那不是"没吸住"。
   *   不满足时必须读成"仪器没准备好"，不是"页面没钉住"。
   */
  ok('两张吸顶图搜索框都已失焦（无光标闪烁的前提）',
      !focusA && !focusB, 'A=$focusA B=$focusB');
  ok('★内容区确实变了（区域限定，排除底部玻璃抖动）', bodyA != bodyB,
      'A=$bodyA B=$bodyB');

  /*
   * ★ 反面参照：静止态的条带区**本来就该**与吸顶态不同
   *   （那里是页头，不是吸顶条）。这一条把"条带区不同"钉在**已知原因**上，
   *   免得上面那条 `stripA == stripB` 只是"整个顶部都没画东西"的假通过。
   */
  ok('反面参照：静止态条带 ≠ 吸顶态条带（那里是页头）', strip0 != stripA,
      '静止=$strip0 吸顶A=$stripA');

  ok('滚动后截图非退化（>20 色）', c3 > 20 && c4 > 20,
      '吸顶A=$c3 吸顶B=$c4');

  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74S]');
  debugPrint('[T74S] ══════ 结束 pass=$pass fail=$fail ══════');
  debugPrint('[T74S] RESULT task-74② 搜索框吸顶：restTop=${restTop.toStringAsFixed(1)} '
      '框top@深滚=${boxTops.last.toStringAsFixed(1)} '
      '内容上移=${cardMoved.toStringAsFixed(1)}px '
      '吸顶A/B条带不变=${stripA == stripB} '
      '吸顶A/B内容变=${bodyA != bodyB} '
      '滑块行数A=$sbA B=$sbB 失焦A=$focusA B=$focusB pass=$pass fail=$fail '
      '| 环境 真机 | 时间 ${DateTime.now().toIso8601String()}');

  await finish(fail == 0 ? 0 : 1);
}
