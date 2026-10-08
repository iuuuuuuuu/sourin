// ═══════════════════════════════════════════════════════════════════════
//  「直播源并入 JS 插件」的真机取证探针（2026-09-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
//
// 这个改动**在 `flutter test` 里测不到渲染**：
// ```text
// SettingsPage.build() 里有 `${SourinApi.version}`
//   → SourinCore.version → _ensureBound()
//   → DynamicLibrary.open('sourin_core.dll')
// 而 flutter test 进程里没有那个 DLL（实测 error code 126）
//   ⇒ build() 抛异常 ⇒ 子树被换成 ErrorWidget
// ```
// （这是 `task43_plugins_subpage_test.dart` 记录的结构墙，已由独立验证者确认。）
// ⇒ 静态契约测试只能证明"接线还在"，**证明不了"页面真的画出来了"**。
//
// # 为什么不用系统鼠标
//
// Owner 明确要求过：
// ```text
// > 不要再操作我的鼠标,你想别的方式去测试,别影响我的工作
// ```
// ⇒ 用 `WidgetsBinding.instance.handlePointerEvent(...)` 注入指针事件 ——
//   那是 **Flutter 框架内部**的派发入口，与真鼠标走的是**同一条路**
//   （`GestureBinding.handlePointerEvent`），但**不碰系统光标、不抢前台**。
//   ★ 这个手法是 `delivery_test.dart:1679` 既有的，照抄不发明。
//
// # 为什么能自己截图（而 `flutter test` 里不行）
//
// `RepaintBoundary.toImage()` 在 **flutter test** 里会挂死
// （要 `tester.runAsync()` → 真定时器 → 10 分钟超时，实测踩过两次）。
// ★ 但这里是**真实应用进程**，没有 fake async 时钟
//   ⇒ `toImage()` 正常工作，且**像素由 Flutter 自己光栅化**，
//     与"屏幕是否解锁""窗口是否在前台"全都无关。
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/merge_view_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\merge-view"
// ```
// ⚠️ **必须**用隔离数据目录 —— 它会读真实库（只读），
//    但 `UiPrefs` 与核心初始化会碰数据目录，不能指向用户真库。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'core/ffi.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/settings_page.dart';
import 'ui/theme_bridge.dart';
import 'ui/widgets/settings_kit.dart';

/// 截图用的重绘边界（包住整棵 UI）
final _rootKey = GlobalKey();

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

void say(String s) => debugPrint('[MV] $s');

int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    debugPrint('[MV] ✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    debugPrint('[MV] ✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final appdata = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$appdata${Platform.pathSeparator}app.sourin.player';
}

// ═══════════════════════════════════════════════════════════════════════
//  截图
// ═══════════════════════════════════════════════════════════════════════

/// 把 `_rootKey` 那棵子树光栅化成 PNG
///
/// ★ 返回 (文件路径, 唯一颜色数) —— 颜色数是**仪器自检**：
///   全黑/全白图只有 1~2 种颜色，那种图不能当证据。
Future<(String, int)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('✗ $name：`_rootKey` 还没有 context（UI 没挂上）');
    return ('', 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('✗ $name：根不是 RenderRepaintBoundary（实际 ${obj.runtimeType}）');
    return ('', 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_outDir\\merge-$name.png';
  File(path).writeAsBytesSync(data!.buffer.asUint8List());

  // 唯一颜色数（自检：退化图不能当证据）
  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    // 每 7 个像素采一个（够估颜色数，又不慢）
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  final w = img.width, h = img.height;
  img.dispose();
  say('  截图 $name: ${w}x$h  ${File(path).lengthSync()} B  采样颜色数=${seen.length}');
  return (path, seen.length);
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树查找 + 指针注入
// ═══════════════════════════════════════════════════════════════════════

/// 在元素树里找第一个 `SettingsEntryRow` 且标题匹配的元素
Element? findEntry(Element root, String title) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is SettingsEntryRow && w.title == title) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 找任意 `Text` 内容匹配的元素（用于"某段文字真的画出来了吗"）
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

/// 收集树里所有 `Text` 的字符串（用于统计）
void collectTexts(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  e.visitChildren((c) => collectTexts(c, out));
}

/// 在 [globalPos] 注入一次**完整单击**（down → 让出事件循环 → up）
///
/// ⚠️ 两次事件之间必须让出一次事件循环：手势竞技场要在**真实的帧**上
///    结算（`kDoubleTapTimeout` / arena sweep 都挂在帧回调上）。
///    同一个 microtask 里连发 down/up 会漏掉 up —— 见
///    `delivery_test.dart:1671-1677` 的实测说明。
Future<void> tapAt(Offset globalPos, {String label = ''}) async {
  const pointer = 91;
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
    pointer: pointer,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
    pointer: pointer,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
  // 等过双击窗口（300ms）—— 否则 onTap 还没派发
  await Future<void>.delayed(const Duration(milliseconds: 700));
  say('  已注入单击 $label @ $globalPos');
}

/// 取元素的**全局中心点**
Offset? centerOf(Element? e) {
  if (e == null) return null;
  final ro = e.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(ro.size.center(Offset.zero));
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  final r = await SourinCore.startAsync(dir);

  debugPrint('[MV] ══════ 直播源并入 JS 插件 —— 真机取证 ══════');
  say('数据目录: $dir');
  say('核心: $r');

  // 窗口尺寸设成与真机一致的 1280x800（不是鼠标操作）
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · merge-view 探针');
  }

  final brightness = AppTheme.resolve(systemBrightness: Brightness.light);
  final theme = AppTheme.themeFor(brightness);
  final materialTheme = brightness == Brightness.light
      ? buildLightMaterialTheme(theme)
      : buildMaterialTheme(theme);

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: FLocalizations.localizationsDelegates,
        supportedLocales: FLocalizations.supportedLocales,
        theme: materialTheme,
        /*
         * ★★★ 必须复刻生产的两层外壳（否则 SettingsPage 变成 ErrorWidget）
         *
         * 我第一版只写了 `builder: (c, child) => FTheme(...)`，
         * 结果启动即抛：
         * ```text
         * Null check operator used on a null value
         * #0  Material.of (package:material_ui/src/material.dart:418)
         * #1  _InkState._build (package:material_ui/src/ink_decoration.dart:306)
         * ```
         * 原因：`SettingsEntryRow` 用 `InkWell`，而 `InkWell` 需要**祖先里有
         * `Material`** 才能画涟漪（那个类的文档专门写了这一点，并说
         * "二级页可能不是 Scaffold，所以这里自带一层 Material 保底" ——
         * 但**一级页**没自带，它依赖生产的外壳）。
         *
         * 生产的结构（`shell.dart:2854-2865`）：
         * ```text
         * ShellScope
         *  └ FScaffold
         *     └ Material(type: MaterialType.transparency)   ← ★ 就是这一层
         *        └ _pageFor(_tab) → SettingsPage
         * ```
         * ⇒ 探针必须**逐字复刻**它，否则测的就不是用户看到的那棵树。
         *   （这正是本仓铁律："测试为了能跑而绕开生产的结构" 是它自己的缺陷类。）
         *
         * ⚠️ 少了它时页面**不会崩给你看** —— 它被换成 `ErrorWidget`，
         *    然后断言以"找不到入口"的形式失败。我第一版就是这样，
         *    报的是「✗ JS 插件入口存在」而不是"缺 Material"。
         *    真正的原因在 stderr 的堆栈里 —— **必须读 stderr**。
         */
        builder: (context, child) => FTheme(
          data: theme,
          child: FScaffold(
            child: Material(
              type: MaterialType.transparency,
              child: child!,
            ),
          ),
        ),
        home: const SettingsPage(),
      ),
    ),
  );

  // ── 等核心数据加载完（卡片列表依赖 listProviders）──────────────
  await Future<void>.delayed(const Duration(seconds: 6));

  final root = _rootKey.currentContext as Element?;
  if (root == null) {
    debugPrint('[MV] ✗ 根元素拿不到，探针无法继续');
    debugPrint('[MV] RESULT pass=$pass fail=$fail');
    exit(1);
  }

  // ═══════════════════════════════════════════════════════════════
  //  ① 一级设置页：独立「直播源」区块必须**不在**
  // ═══════════════════════════════════════════════════════════════
  debugPrint('[MV]');
  debugPrint('[MV] ── ① 一级设置页 ──');
  final texts1 = <String>[];
  collectTexts(root, texts1);
  say('  树里 Text 数 = ${texts1.length}');

  final hasLiveBlockTitle = texts1.any((t) => t == '直播源');
  ok('独立「直播源」区块标题**不存在**', !hasLiveBlockTitle,
      hasLiveBlockTitle ? '★ 仍找到「直播源」三个字' : '');

  final hasJsEntry = texts1.any((t) => t == 'JS 插件');
  ok('JS 插件入口**存在**', hasJsEntry);

  // 入口副标题（能看出里面有什么）
  final sub = texts1.where((t) => t.contains('个内容源')).toList();
  say('  入口副标题候选: $sub');
  ok('入口副标题说明了内容', sub.isNotEmpty);

  final (p1, c1) = await shoot('01-settings');
  ok('① 截图非退化（颜色数 > 20）', c1 > 20, '颜色数=$c1');

  // ═══════════════════════════════════════════════════════════════
  //  ② 点进 JS 插件二级页
  // ═══════════════════════════════════════════════════════════════
  debugPrint('[MV]');
  debugPrint('[MV] ── ② 点 JS 插件入口 ──');
  final entry = findEntry(root, 'JS 插件');
  final c = centerOf(entry);
  ok('找到 JS 插件入口元素且可算中心点', c != null, '中心=$c');
  if (c == null) {
    debugPrint('[MV] RESULT pass=$pass fail=$fail');
    exit(fail == 0 ? 0 : 1);
  }
  await tapAt(c, label: 'JS 插件入口');
  await Future<void>.delayed(const Duration(seconds: 2)); // 等路由推入 + 数据

  // ═══════════════════════════════════════════════════════════════
  //  ③ 二级页：必须看到「直播 N/M」汇总 chip + 源卡片
  // ═══════════════════════════════════════════════════════════════
  debugPrint('[MV]');
  debugPrint('[MV] ── ③ JS 插件二级页 ──');
  final root2 = _rootKey.currentContext as Element?;
  if (root2 == null) {
    debugPrint('[MV] ✗ 二级页根元素拿不到');
    debugPrint('[MV] RESULT pass=$pass fail=$fail');
    exit(1);
  }
  final texts2 = <String>[];
  collectTexts(root2, texts2);
  say('  树里 Text 数 = ${texts2.length}');

  // 「直播 N/M」chip：文案是 '直播 ' + 'N' + '/M' 三段拼的
  // ⇒ 直接找以 '直播 ' 开头的
  final liveChips = texts2.where((t) => t.startsWith('直播 ')).toList();
  say('  「直播 N/M」chip 候选 = $liveChips');
  ok('块头有「直播 N/M」汇总 chip', liveChips.isNotEmpty);

  // 直播页提示的旧文案**不该**出现在这里（那是另一个页面，但顺手查）
  final stale = texts2.where((t) => t.contains('设置 → 直播源')).toList();
  ok('页面上没有「设置 → 直播源」死链', stale.isEmpty, '$stale');

  // 源卡片：应能看到若干源名 + 「直播」能力 chip
  final capLive = texts2.where((t) => t == '直播').length;
  say('  能力 chip「直播」出现次数 = $capLive');
  ok('卡片上有「直播」能力 chip', capLive >= 1, '次数=$capLive');

  // 启停按钮（合并后**唯一**的启停入口）
  final toggleBtns = texts2.where((t) => t == '停用' || t == '启用').length;
  say('  「启用/停用」按钮数 = $toggleBtns');
  ok('卡片上仍有「启用/停用」按钮（启停入口没丢）', toggleBtns >= 1,
      '次数=$toggleBtns');

  final (p2, c2) = await shoot('02-plugins');
  ok('② 截图非退化（颜色数 > 20）', c2 > 20, '颜色数=$c2');

  // ═══════════════════════════════════════════════════════════════
  //  ④ 返回一级页（证明能回去）
  // ═══════════════════════════════════════════════════════════════
  debugPrint('[MV]');
  debugPrint('[MV] ── ④ 点「返回设置」──');
  final back = findText(root2, '返回设置');
  final bc = centerOf(back);
  ok('找到「返回设置」按钮', bc != null, '中心=$bc');
  if (bc != null) {
    await tapAt(bc, label: '返回设置');
    await Future<void>.delayed(const Duration(seconds: 1));
    final root3 = _rootKey.currentContext as Element?;
    final texts3 = <String>[];
    if (root3 != null) collectTexts(root3, texts3);
    final backOk = texts3.any((t) => t == 'JS 插件') &&
        !texts3.any((t) => t.startsWith('直播 '));
    ok('回到了一级页（JS 插件入口在、直播 chip 不在）', backOk);
  }

  debugPrint('[MV]');
  debugPrint('[MV] ══════ 结果: pass=$pass fail=$fail ══════');
  debugPrint('[MV] RESULT pass=$pass fail=$fail');
  say('截图: $p1 / $p2');

  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(fail == 0 ? 0 : 1);
}
