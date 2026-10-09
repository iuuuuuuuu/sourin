// ═══════════════════════════════════════════════════════════════════════
//  task-13 · 备份「执行日志」—— **真机实测**探针
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须上真机（而不是 flutter test）
// ```text
// ① 日志的产生路径要**真的跑一次导出** —— 那会弹**系统保存对话框**，
//    flutter_tester 里没有窗口，这条路径根本走不通。
// ② 要读的是真实数据目录下 logs/ 里**落盘**的那份文件（AppLog 会落盘），
//    那是进程级设施，只有真进程才有。
// ```
//
// # 怎么把「系统保存框」换成可自动化的替身（本探针最关键的一步）
// ```text
// 系统保存框是**模态**的：它一直等你点"保存/取消"，探针点不了。
// 所以这里替换的是 **file_selector 官方留的注入点**
//   FileSelectorPlatform.instance
// ——**不是**本面板的代码。面板仍然走它自己那条
//   _doExport → _pickSavePath → getSaveLocation → _ensureZip
// 真实分支，只是最后那一跳落到了替身上。
//
// ★ 这**不是**"测了影子实现"：
//   影子实现指的是**在探针里另写一份业务逻辑**（本项目明令禁止）。
//   这里业务逻辑只有一份（产品里的那份），替身只替"操作系统对话框"
//   这个**外部环境**。
// ```
//
// # 判据（全是**读数**，不是"没报错"）
// ```text
// ① 真导出：替身被调用 1 次、.zip 真的落盘、字节数 > 0
// ② AppLog 里真的出现 tag=BACKUP 的行，且覆盖"开始 / 已选定 / 成功"三阶段
// ③ 那些行**渲染进了面板**（从 Element 树里捞 Text.data）
// ④ 结构顺序：日志区在导入卡片**之后**
// ⑤ 容量上限：灌 logCap+20 行 BACKUP，面板最多只渲染 logCap 行，
//    且**最早的那些不见了**（证明留的是"最近 N 行"，不是"前 N 行"）
// ⑥ 脱敏：写一条含 token= 的日志，面板里必须看到 <已脱敏>、看不到原文
// ⑦ 落盘：logs/sourin-YYYY-MM-DD.log 里含刚写的 BACKUP 行
// ```
//
// 用法：
// ```powershell
// flutter build windows --release -t lib/t13_backup_log_probe.dart "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t13-data"
// ```
// ⚠️ **必须**用隔离数据目录：导出会真的写 .zip，日志会真的落盘。
//
// ⚠️ 本文件是**探针**（临时脚手架），不是产品代码：它只 import 产品文件、
//    不改它们；跑完由调用方删掉（见 .probe/ 的既有约定）。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

// ★ 只为了拿 `FileSelectorPlatform.instance` 这个**官方注入点**（替掉系统保存框）。
//   它是 `file_selector` 的传递依赖，不在 pubspec 里；而 pubspec 不在本任务
//   写范围内 ⇒ 这里只对本行做 ignore（探针是临时脚手架，不进产品）。
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_log.dart';
import 'core/device.dart';
import 'core/ffi.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/settings_page.dart';
import 'ui/widgets/backup_panel.dart';
import 'ui/widgets/settings_sub_page.dart';

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';
const String _tag = String.fromEnvironment('T13_TAG', defaultValue: 'run1');

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  trace(s);
  debugPrint('[T13] $s');
}

void note(String s) => say('·  $s');

/*
 * ★★ 同步落盘的**进度追踪** —— 本探针唯一的可靠诊断通道。
 *
 * # 为什么不能用 debugPrint
 * ```text
 * Windows 上 Flutter 产物是 **GUI 子系统** exe ⇒ 不挂控制台 ⇒
 * print/debugPrint 写进的 stdout **没有接收端**。
 * 实测：`& exe *> out.txt` 得到 **0 字节**（第一次跑就是这样，
 * 探针卡住了却什么都看不到 ⇒ 只能靠"文件到底写没写"猜）。
 * ```
 *
 * # 为什么必须 flush: true
 * ```text
 * 探针**卡死**时进程不会正常退出 ⇒ 缓冲区里的内容永远不会落盘。
 * 只有每行都 flush，才能看到"**卡在哪一步**"（而不是"什么都没写"）。
 * ```
 */
final File _traceFile = File('$_outDir\\t13-trace-$_tag.txt');

void trace(String s) {
  try {
    _traceFile.writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $s\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 追踪失败绝不能影响主流程
  }
}

void ok(String line, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  say('${cond ? '✓' : '✗'} $line${extra.isEmpty ? '' : '   $extra'}');
}

/// ★ 看门狗：探针**卡死**时也要留下读数（否则外面只能看到"超时"）。
void armWatchdog() {
  Timer(const Duration(seconds: 210), () {
    trace('★★ WATCHDOG 触发（210 秒未跑完）⇒ 强制落盘并退出');
    try {
      File('$_outDir\\t13-backup-log-$_tag.txt').writeAsStringSync(
        '${_log.join('\n')}\n★ WATCHDOG TIMEOUT（210 秒）—— 上面是卡住前拿到的全部读数\n',
        flush: true,
      );
    } catch (_) {}
    exit(9);
  });
}

Future<Never> finish(int code) async {
  final f = File('$_outDir\\t13-backup-log-$_tag.txt');
  try {
    f.writeAsStringSync('${_log.join('\n')}\n');
  } catch (e) {
    debugPrint('[T13] ★ 产物写入失败: $e');
  }
  trace('finish($code) 产物 = ${f.path}  ${f.existsSync() ? f.lengthSync() : -1} B  pass=$pass fail=$fail');
  debugPrint('[T13] RESULT pass=$pass fail=$fail');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(code);
}

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    await Directory(override).create(recursive: true);
    return override;
  }
  final appData = Platform.environment['APPDATA'] ?? '.';
  return '$appData\\app.sourin.player';
}

// ══════════════════════════════════════════════════════════════════════
// 替身：只替「操作系统保存对话框」这一跳
// ══════════════════════════════════════════════════════════════════════

/// 假的保存对话框：不弹窗，直接返回 [targetPath]。
///
/// ⚠️ 必须 `extends`（不是 `implements`）—— file_selector 的 platform
///    interface 用 token 校验实现方式，`implements` 会在赋值时抛
///    AssertionError（plugin_platform_interface 的 verify）。
class _SaveStub extends FileSelectorPlatform {
  _SaveStub(this.targetPath);

  final String targetPath;

  /// 被调用次数（判据 ①：必须是 1 —— 证明**真的走了**弹框那一步）
  int calls = 0;

  /// 面板传进来的 suggestedName（证明默认文件名真的流到了对话框）
  String? lastSuggestedName;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    calls++;
    lastSuggestedName = options.suggestedName;
    return FileSaveLocation(targetPath);
  }
}

/// 假对话框：**用户取消**（返回 null）。
///
/// ★ 用它触发面板的"取消"分支 —— 那条分支同样会 _log + setState，
///   正好能当"让面板重新取一次日志"的手段（面板就是"写完就重建"）。
class _CancelStub extends FileSelectorPlatform {
  int calls = 0;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    calls++;
    return null;
  }
}

// ══════════════════════════════════════════════════════════════════════
// 元素树 / 几何
// ══════════════════════════════════════════════════════════════════════

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

void collectTexts(Element root, List<String> out) {
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

String rectStr(Rect? r) => r == null
    ? 'null'
    : '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)})'
        '-(${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)})'
        ' ${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

// ══════════════════════════════════════════════════════════════════════
// 帧 / 事件
// ══════════════════════════════════════════════════════════════════════

/// ★ 必须带 timeout：万一没人请求帧，endOfFrame 会一直挂着 ⇒ 静默停住。
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

/// ★ 两次事件之间必须让出事件循环 —— 同一 microtask 里连发 down/up 会漏掉 up。
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

/// onTap 要等过 kDoubleTapTimeout(300ms) 才派发 ⇒ 多等 700ms。
Future<void> tapAndSettle(Offset globalPos) async {
  await tapAt(globalPos);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpFrame();
}

Future<void> settleOverlays() async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrame();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpFrame();
}

/// 把 [find] 找到的元素滚进安全带（避开标题栏 / 底部条）。
Future<bool> bringIntoBand(
  Element scope,
  Element? Function() find, {
  double lo = 120,
  double hi = 700,
  int tries = 8,
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

// ══════════════════════════════════════════════════════════════════════
// 截图
// ══════════════════════════════════════════════════════════════════════

final GlobalKey _rootKey = GlobalKey();

class Shot {
  Shot(this.path, this.w, this.h, this.colors);

  final String path;
  final int w;
  final int h;
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
  final path = '$_outDir\\t13-$_tag-$name.png';
  await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);

  // 仪器自检：每 7 像素采样一次数颜色（退化图只有 1~2 色）
  final set = <int>{};
  for (var y = 0; y < h; y += 7) {
    for (var x = 0; x < w; x += 7) {
      final o = y * w * 4 + x * 4;
      set.add((bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2]);
    }
  }
  return Shot(path, w, h, set.length);
}

// ══════════════════════════════════════════════════════════════════════
// 按钮定位（按**可见文字**找，而不是按类型顺序猜）
// ══════════════════════════════════════════════════════════════════════

bool _subtreeHasText(Element e, String s) {
  var hit = false;
  void walk(Element x) {
    if (hit) return;
    final w = x.widget;
    if (w is Text && w.data == s) hit = true;
    x.visitChildren(walk);
  }

  walk(e);
  return hit;
}

Element? buttonByText(Element root, String label, {required bool filled}) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    final isBtn = filled ? (w is FilledButton) : (w is OutlinedButton);
    if (isBtn && _subtreeHasText(e, label)) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 从 [scope] 子树里捞出"像一行备份日志"的 Text.data。
///
/// 判据就是 AppLog 的 LogLine.text 格式：
///   `yyyy-MM-dd HH:mm:ss.SSS [BACKUP] 正文`
final RegExp _logRowRe =
    RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[BACKUP\] ');

List<String> logRowsIn(Element scope) {
  final all = <String>[];
  collectTexts(scope, all);
  return all.where(_logRowRe.hasMatch).toList();
}

// ══════════════════════════════════════════════════════════════════════
// main
// ══════════════════════════════════════════════════════════════════════

/*
 * ★★ 外层守卫：`main()` 里任何**逃出的异常**都必须留下读数。
 *
 * # 为什么（第一次真机实测踩到的）
 * ```text
 * 第一次跑探针：trace 停在 `dataDir = …` 之后，进程**活着但 0 CPU**、
 * 窗口都没起来 —— 而 debugPrint 在这份 GUI 子系统 exe 里**没有接收端**
 * ⇒ 异常信息**完全丢失**，只能看到"卡住了"。
 * ⇒ 用 try/catch 把异常与栈**同步写进 trace 文件**。
 * ```
 */
Future<void> main() async {
  try {
    await _main();
  } catch (e, st) {
    trace('★★ main() 逃出异常：$e');
    trace('$st');
    try {
      File('$_outDir\\t13-backup-log-$_tag.txt').writeAsStringSync(
        '★ 探针在 main() 阶段就崩了，一条判据都没跑\n$e\n$st\n',
        flush: true,
      );
    } catch (_) {}
    exit(2);
  }
}

Future<void> _main() async {
  trace('══════ main() 进入 ══════');
  armWatchdog();
  WidgetsFlutterBinding.ensureInitialized();
  trace('WidgetsFlutterBinding 就绪');

  // ★ 必须在 runApp 之前（shell.dart 的同一条）
  trace('MediaKit.ensureInitialized 之前');
  MediaKit.ensureInitialized();
  trace('MediaKit.ensureInitialized 之后');
  await Device.init();
  trace('Device.init 之后');

  final dir = await _resolveDataDir();
  trace('dataDir = $dir');
  await UiPrefs.load(dir);
  trace('UiPrefs.load 之后');

  // ★ 强制浅色：去掉"跑的那一刻系统主题"这个外部变量（写的是隔离目录）
  AppTheme.setMode(AppThemeMode.light);

  String? coreError;
  try {
    trace('SourinCore.startAsync 之前');
    final r = await SourinCore.startAsync(dir);
    trace('SourinCore.startAsync 之后 = $r');
    say('核心启动 = $r');
  } catch (e) {
    coreError = e.toString();
    say('★ 核心启动失败 = $coreError');
  }

  try {
    trace('LiquidGlassWidgets.initialize 之前');
    await LiquidGlassWidgets.initialize();
    trace('LiquidGlassWidgets.initialize 之后');
  } catch (e) {
    note('LiquidGlassWidgets.initialize 失败: $e');
  }

  trace('窗口设置之前');
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    /*
     * ★ 窗口选项逐字复刻生产（titleBarStyle.hidden 会去掉系统标题栏，
     *   自绘标题栏才占得住顶部 ~39px；否则 y 坐标全部错位）。
     * ⚠️ 刻意**不**调 windowManager.focus()（生产有）—— 会抢 Owner 焦点。
     * ★ 必须 show()：窗口不可见时引擎可能整帧不产出。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t13 备份执行日志取证 ($_tag)',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    trace('窗口已 show');
  }

  // ★ 外壳 = 生产本体（不是复刻）
  trace('runApp 之前');
  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));

  trace('runApp 之后 ⇒ 进 _body');
  try {
    await _body(dir);
  } catch (e, st) {
    // ★ 异常逃出会让探针**静默停住**，外层只看到超时 ⇒ 必须报出来
    ok('★ 探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}

// ══════════════════════════════════════════════════════════════════════
// 正文
// ══════════════════════════════════════════════════════════════════════

Future<void> _body(String dir) async {
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 立刻中止（导出会真的写 .zip，日志会真的落盘）');
    await finish(1);
  }

  // ★ 仪器读数：这一轮到底加载的是哪个核心（读数要能对上真机环境）
  try {
    say('核心版本 = ${SourinApi.version}');
  } catch (e) {
    note('SourinApi.version 读不到: $e');
  }

  // ★ 起点：进程刚起来，BACKUP 这个 tag 应该一条都没有
  final rowCount0 =
      AppLog.lines.where((l) => l.tag == 'BACKUP').length;
  note('进程启动至今 tag=BACKUP 的行数 = $rowCount0（AppLog 总条数 = ${AppLog.lineCount}）');
  ok('⓪ 起点成立：还没有任何 BACKUP 日志（否则后面"日志出现了"可能来自别处）',
      rowCount0 == 0, 'rowCount0=$rowCount0');

  trace('_body：等 shell 挂载…');
  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ 生产外壳 SourinApp 挂载（debugShellKey.currentState != null）', shellUp);

  final root0 = _rootKey.currentContext;
  if (!shellUp || root0 == null) {
    say('★ 外壳没起来 ⇒ 中止');
    await finish(1);
  }

  final rootEl = root0 as Element;
  await Future<void>.delayed(const Duration(seconds: 2));
  await pumpFrame();

  // ── ① 进「备份与恢复」二级页 ──────────────────────────────────────────
  say('');
  say('──────── ① 进「备份与恢复」二级页 ────────');

  trace('切到设置页…');
  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await pumpFrame();

  final l1Up = await waitUntil(
    () => findText(rootEl, '内容源、网络与同步') != null,
    timeout: const Duration(seconds: 30),
    label: '设置页页头',
  );
  ok('① 设置页已渲染', l1Up);
  if (!l1Up) {
    await finish(1);
  }

  Element? entryFinder() =>
      findText(rootEl, '备份与恢复') ??
      findTextContains(rootEl, '导出 / 导入本机数据');
  /*
   * ★★ 滚动范围必须是**设置页自己**那个 Scrollable。
   *   `scrollableIn(rootEl)` 会拿到**全树第一个** —— 而外壳把各页
   *   都留在树上（切页不销毁），第一个很可能是**首页**的滚动条
   *   ⇒ 滚的是另一个页面，入口行永远进不了安全带（假红）。
   *   t87 就是按"页元素"取范围的（`bringIntoBand(settingsEl, …)`）。
   */
  final settingsEl = findWidget(rootEl, (w) => w is SettingsPage);
  ok('① 拿到一级页范围锚点 SettingsPage 元素', settingsEl != null);
  if (settingsEl == null) {
    say('★ 没有 SettingsPage 锚点 ⇒ 中止');
    await finish(1);
  }
  final entryIn = await bringIntoBand(settingsEl, entryFinder);
  final entryRect = rectOf(entryFinder());
  note('入口行 rect = ${rectStr(entryRect)}  inBand=$entryIn');
  ok('① 入口行可达', entryIn, rectStr(entryRect));
  if (!entryIn || entryRect == null) {
    say('★ 入口行点不到 ⇒ 中止');
    await finish(1);
  }

  trace('点入口行 rect=${rectStr(entryRect)}');
  await tapAndSettle(entryRect.center);
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await pumpFrame();

  trace('等 BackupPanel 挂载…');
  final subUp = await waitUntil(
    () => findWidget(rootEl, (w) => w is BackupPanel) != null,
    timeout: const Duration(seconds: 20),
    label: 'BackupPanel 挂载',
  );
  ok('① 点了入口行 ⇒ BackupPanel 真的挂上来了', subUp);
  if (!subUp) {
    say('★ 面板没上来 ⇒ 中止');
    await finish(1);
  }

  final subEl = findWidget(rootEl, (w) => w is SettingsSubPage)!;
  final bakEl = findWidget(rootEl, (w) => w is BackupPanel)!;
  note('SettingsSubPage 子树元素数 = ${elementCount(subEl)}');
  note('BackupPanel 子树元素数 = ${elementCount(bakEl)}');
  ok('① 真的进了「备份与恢复」二级页（树里有 SettingsSubPage）',
      findWidget(rootEl, (w) => w is SettingsSubPage) != null);
  ok('① 二级页标题在（Text("备份与恢复")）',
      findText(rootEl, '备份与恢复') != null);
  ok('① 面板标题「执行日志」在树上', findText(bakEl, '执行日志') != null);
  ok('① 面板标题「导出备份」在树上', findText(bakEl, '导出备份') != null);
  ok('① 面板标题「导入备份」在树上', findText(bakEl, '导入备份') != null);

  // ── ② 空态（还没有任何操作时）─────────────────────────────────────────
  say('');
  say('──────── ② 空态：还没操作过 ────────');

  final emptyEl = findTextContains(bakEl, '还没有记录');
  ok('② 空态文案在（「还没有记录…」）', emptyEl != null);
  if (emptyEl != null) {
    note('空态原文 = 「${(emptyEl.widget as Text).data}」');
  }
  final rows0 = logRowsIn(bakEl);
  ok('② 此刻面板渲染的日志行数 = 0', rows0.isEmpty, '实际=${rows0.length}');
  ok('② 行数计数器显示「0 行」', findText(bakEl, '0 行') != null);

  // ── ③ 真跑一次导出（系统保存框换成替身）────────────────────────────────
  say('');
  say('──────── ③ 真跑一次导出（合成指针点界面按钮）────────');

  final zipPath = '$dir\\t13-export-out\\dsh-backup-probe.zip';
  await Directory('$dir\\t13-export-out').create(recursive: true);
  // ★ 先确保目标不存在 —— 否则"文件在"可能来自上一轮
  final zipFile = File(zipPath);
  if (zipFile.existsSync()) zipFile.deleteSync();
  ok('③ 起点成立：目标 .zip 原本不存在', !zipFile.existsSync(), zipPath);

  trace('装保存框替身 → $zipPath');
  final stub = _SaveStub(zipPath);
  FileSelectorPlatform.instance = stub;
  note('已把 FileSelectorPlatform.instance 换成替身（只替"系统对话框"这一跳）');

  Element? exportBtn() => buttonByText(bakEl, '导出', filled: true);
  final btnIn = await bringIntoBand(subEl, exportBtn);
  final btnEl = exportBtn();
  var btnRect = rectOf(btnEl);
  note('「导出」按钮 rect = ${rectStr(btnRect)}  inBand=$btnIn');
  ok('③ 「导出」按钮找得到（FilledButton 子树含 Text(导出)）', btnEl != null);

  /*
   * ★ 按钮可能贴在安全带下沿之外（页面很短时滚不动）。
   *   点不了就**如实报仪器失败**，不要拿"跳过"当通过。
   */
  if (btnRect == null || btnRect.center.dy < 70 || btnRect.center.dy > 780) {
    say('★ 按钮不在可点范围内（rect=${rectStr(btnRect)}）⇒ 中止');
    await settleOverlays();
    final s = await shoot('03-button-unreachable');
    note('现场 ${s.path} 颜色数=${s.colors}');
    await finish(1);
  }

  final before = AppLog.lines.where((l) => l.tag == 'BACKUP').length;
  trace('点「导出」按钮 rect=${rectStr(btnRect)} before=$before');
  await tapAndSettle(btnRect.center);
  trace('已点「导出」');

  // 导出要跑 FFI 打包，给它足够时间
  final done = await waitUntil(
    () => AppLog.lines.where((l) => l.tag == 'BACKUP').length >= before + 3,
    timeout: const Duration(seconds: 90),
    label: '导出日志三阶段',
  );
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await pumpFrame();
  ok('③ 点「导出」后 BACKUP 日志真的多出 >= 3 行', done,
      'before=$before  现在=${AppLog.lines.where((l) => l.tag == 'BACKUP').length}');

  ok('③ ★替身被调用恰好 1 次（证明真的走到了弹框那一步）', stub.calls == 1,
      'calls=${stub.calls}  suggestedName=${stub.lastSuggestedName}');
  ok('③ 面板传给对话框的默认文件名以 .zip 结尾',
      (stub.lastSuggestedName ?? '').toLowerCase().endsWith('.zip'),
      'suggestedName=${stub.lastSuggestedName}');

  final zf = File(zipPath);
  final zBytes = zf.existsSync() ? zf.lengthSync() : -1;
  ok('③ ★.zip 真的落盘且非空', zBytes > 0, '$zipPath = $zBytes B');

  // ── ④ AppLog 里真的有那几行，且**渲染进了面板** ──────────────────────
  say('');
  say('──────── ④ 日志既要"写了"，也要"画出来了" ────────');

  List<String> backupRows() => AppLog.lines
      .where((l) => l.tag == 'BACKUP')
      .map((l) => l.text)
      .toList();

  final written = backupRows();
  note('AppLog 里 tag=BACKUP 的行（**存储侧读数**）:');
  for (final t in written) {
    note('   $t');
  }

  String? msgOf(List<String> rows, String needle) {
    for (final r in rows) {
      if (r.contains(needle)) return r;
    }
    return null;
  }

  ok('④ 存储侧有「导出：开始」', msgOf(written, '导出：开始') != null);
  ok('④ 存储侧有「导出：已选定 …，开始打包…」',
      msgOf(written, '开始打包') != null);
  ok('④ 存储侧有「导出：成功 …（大小）—— 打包 X ms / 全程 Y ms」',
      msgOf(written, '导出：成功') != null);
  ok('④ 存储侧**没有**「导出：失败」', msgOf(written, '导出：失败') == null,
      msgOf(written, '导出：失败') ?? '');

  final rendered = logRowsIn(bakEl);
  note('面板渲染出来的日志行（**渲染侧读数**）:');
  for (final t in rendered) {
    note('   $t');
  }

  /*
   * ★★ 同源对照：存储侧写的每一行，都应该在渲染侧**逐字**找得到。
   *   ⚠️ 只比"条数相等"是不够的 —— 那可能在画别的东西。
   */
  var matched = 0;
  for (final w in written) {
    if (rendered.contains(w)) matched++;
  }
  ok('④ ★存储侧 $written.length 行**逐字**都出现在渲染侧',
      matched == written.length, 'matched=$matched / ${written.length}');
  ok('④ 渲染侧行数与存储侧一致（没有多画/少画）',
      rendered.length == written.length,
      '渲染=${rendered.length} 存储=${written.length}');

  // 计时读数真的落进文案了吗
  final successRow = msgOf(rendered, '导出：成功');
  final hasMs = successRow != null &&
      RegExp(r'打包 \d+ ms / 全程 \d+ ms').hasMatch(successRow);
  ok('④ 成功那行带**真实毫秒读数**（打包 X ms / 全程 Y ms）', hasMs,
      successRow ?? '(没有这一行)');

  // ── ⑤ 结构顺序：日志区在两张卡片**之后** ─────────────────────────────
  say('');
  say('──────── ⑤ 结构顺序 ────────');

  final logTitleRect = rectOf(findText(bakEl, '执行日志'));
  final expTitleRect = rectOf(findText(bakEl, '导出备份'));
  final impTitleRect = rectOf(findText(bakEl, '导入备份'));
  note('「执行日志」rect = ${rectStr(logTitleRect)}');
  note('「导出备份」rect = ${rectStr(expTitleRect)}');
  note('「导入备份」rect = ${rectStr(impTitleRect)}');
  ok('⑤ 日志区在「导出备份」卡片**下方**',
      logTitleRect != null && expTitleRect != null &&
          logTitleRect.top > expTitleRect.top,
      '日志.top=${logTitleRect?.top}  导出.top=${expTitleRect?.top}');
  ok('⑤ 日志区在「导入备份」卡片**下方**',
      logTitleRect != null && impTitleRect != null &&
          logTitleRect.top > impTitleRect.top,
      '日志.top=${logTitleRect?.top}  导入.top=${impTitleRect?.top}');

  final counterRe = RegExp(r'^\d+ 行$');
  final counterEl = findWidget(
      bakEl, (w) => w is Text && counterRe.hasMatch(w.data ?? ''));
  if (counterEl != null) {
    note('行数计数器原文 = 「${(counterEl.widget as Text).data}」');
  } else {
    note('★ 没找到"N 行"计数器');
  }
  ok('⑤ 行数计数器显示「${rendered.length} 行」（与渲染条数一致）',
      findText(bakEl, '${rendered.length} 行') != null);

  say('');
  trace('导出后：存储侧 ${written.length} 行 / 渲染侧 ${rendered.length} 行');
  await settleOverlays();
  final s1 = await shoot('04-log-after-export');
  note('截图 ${s1.path}  ${s1.w}x${s1.h}  采样颜色数=${s1.colors}');
  ok('⓪ 截图非退化（>20 色）', s1.colors > 20, '颜色数=${s1.colors}');

  // ── ⑥ 容量上限 ────────────────────────────────────────────────────────
  say('');
  say('──────── ⑥ 容量上限（灌 logCap+20 行）────────');

  /*
   * ★ 怎么做出"超过上限"：直接往 AppLog 灌 BACKUP 行 ——
   *   这正是产品的**唯一**写入方式（面板自己也只调 AppLog.write），
   *   不是另写一份业务逻辑。
   * ⚠️ 灌完必须让面板**重建**一次才会重新取数（它就是"写完就重建"），
   *   所以下面用一次"取消导出"来触发：_log 会写 + setState。
   */
  /*
   * ★ logCap 是**私有静态常量**，探针读不到 ⇒ 从**源码文本**里读出来，
   *   这样"上限"这个读数是自己核对过的，而不是抄来的。
   *   （读不到就退回 300 并**明确报出来**，不静默假设。）
   */
  var cap = 300;
  final panelSrc =
      File('lib/ui/widgets/backup_panel.dart').readAsStringSync();
  final capM = RegExp(r'static const int logCap = (\d+);')
      .firstMatch(panelSrc);
  ok('⑥ 从源码里读到了 logCap', capM != null);
  if (capM != null) cap = int.parse(capM.group(1)!);
  note('源码 logCap = $cap');
  trace('灌容量测试行 cap=$cap');
  const extra = 20;
  for (var i = 0; i < cap + extra; i++) {
    AppLog.write('BACKUP', '容量测试 #$i 结束');
  }
  AppLog.write('BACKUP', '脱敏测试 token=SECRETVALUE123456');
  note('已灌入 ${cap + extra} 行「容量测试 #n」+ 1 行脱敏测试');

  final stub2 = _CancelStub();
  FileSelectorPlatform.instance = stub2;
  note('换成替身：返回 null = 用户取消 → 触发一次 _log + setState');
  // ★ 导出让下方多了一行结果文案 ⇒ 按钮位置会挪，必须**重新**找 + 滚
  await bringIntoBand(subEl, exportBtn);
  final btn2 = rectOf(exportBtn());
  note('第二次「导出」按钮 rect = ${rectStr(btn2)}');
  ok('⑥ 第二次也点得到「导出」按钮',
      btn2 != null && btn2.center.dy >= 70 && btn2.center.dy <= 780,
      rectStr(btn2));
  await tapAndSettle(btn2!.center);
  await Future<void>.delayed(const Duration(seconds: 2));
  await pumpFrame();
  ok('⑥ 取消替身被调用 1 次（证明那次点击真的走到了它）', stub2.calls == 1,
      'calls=${stub2.calls}');

  final rendered2 = logRowsIn(bakEl);
  note('灌完之后面板渲染的日志条数 = ${rendered2.length}（上限应为 $cap）');
  ok('⑥ ★渲染条数被**夹在上限 $cap**',
      rendered2.length == cap, '实际=${rendered2.length}');

  final total2 = AppLog.lines.where((l) => l.tag == 'BACKUP').length;
  note('此刻 AppLog 里 BACKUP 总条数 = $total2（> $cap 才有夹的效果）');
  ok('⑥ 前提成立：存储侧确实超过上限（否则测不到夹）', total2 > cap,
      'total=$total2  cap=$cap');

  ok('⑥ ★最早那批**不见了**（容量测试 #0 不在渲染侧）',
      !rendered2.any((t) => t.contains('容量测试 #0 结束')),
      '渲染侧含 #0 = ${rendered2.any((t) => t.contains('容量测试 #0 结束'))}');
  ok('⑥ ★最近那批**在**（容量测试 #${cap + extra - 1} 在渲染侧）',
      rendered2.any((t) => t.contains('容量测试 #${cap + extra - 1} 结束')));
  ok('⑥ 留的是**尾部**而不是头部（首尾两侧读数同时成立 ⇒ 不是碰巧）',
      !rendered2.any((t) => t.contains('容量测试 #1 结束')) &&
          rendered2.any((t) => t.contains('容量测试 #${cap + extra - 1} 结束')));

  // ── ⑦ 脱敏 ────────────────────────────────────────────────────────────
  say('');
  say('──────── ⑦ 脱敏（token= 不得进日志区）────────');

  final redactedSeen = rendered2.any((t) => t.contains('<已脱敏>'));
  final leakSeen = rendered2.any((t) => t.contains('SECRETVALUE123456'));
  final redactedRow = rendered2.firstWhere(
      (t) => t.contains('脱敏测试'),
      orElse: () => '(没有这一行)');
  note('脱敏那一行渲染成 = $redactedRow');
  ok('⑦ ★面板里出现 <已脱敏>', redactedSeen);
  ok('⑦ ★面板里**看不到**原文 SECRETVALUE123456', !leakSeen, 'leak=$leakSeen');
  ok('⑦ 脱敏命中计数 > 0（证明替换真的发生过）', AppLog.redactedCount > 0,
      'redactedCount=${AppLog.redactedCount}');

  say('');
  await settleOverlays();
  final s2 = await shoot('05-log-cap');
  note('截图 ${s2.path}  ${s2.w}x${s2.h}  采样颜色数=${s2.colors}');

  // ── ⑧ 落盘 ────────────────────────────────────────────────────────────
  say('');
  say('──────── ⑧ 落盘（<dataDir>/logs）────────');

  trace('等落盘…');
  await Future<void>.delayed(const Duration(seconds: 2));
  final logFile = await AppLog.todayFile();
  note('今天的日志文件 = ${logFile.path}');
  ok('⑧ 日志文件真的存在', logFile.existsSync());
  if (logFile.existsSync()) {
    final txt = logFile.readAsStringSync();
    note('文件大小 = ${logFile.lengthSync()} B');
    ok('⑧ 落盘文件里含 [BACKUP] 行', txt.contains('[BACKUP]'));
    ok('⑧ 落盘文件里含刚写的「容量测试 #${cap + extra - 1}」',
        txt.contains('容量测试 #${cap + extra - 1}'));
    ok('⑧ ★落盘文件里**没有** SECRETVALUE123456（脱敏在入库前，磁盘也不该有）',
        !txt.contains('SECRETVALUE123456'));
    /*
     * ★ 隐私判据：日志里不得出现**完整路径**（桌面路径含用户名）。
     *   面板写的是 _fileName()，这里核实真的只有文件名。
     */
    ok('⑧ ★落盘文件里不含数据目录路径（只写了文件名，没写完整路径）',
        !txt.contains(dir));
  }

  // ── 收尾 ──────────────────────────────────────────────────────────────
  say('');
  say('──────── 汇总 ────────');
  say('pass=$pass fail=$fail');
  await settleOverlays();
  final s3 = await shoot('99-final');
  note('截图 ${s3.path}  ${s3.w}x${s3.h}  采样颜色数=${s3.colors}');

  await finish(fail == 0 ? 0 : 1);
}
