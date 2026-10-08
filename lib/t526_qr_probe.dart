// lib/t526_qr_probe.dart
//
// A8 / Trellis 4.5 扫码登录 —— **设备端渲染取证**（可选加分证据）
//
// # 为什么还需要这个探针
//
// 已有两条证据链，但它们各自缺一块：
// ```text
// · cargo test --test t525_qr_login  → 证明「命令层真的通」
//                                       （真 HTTP 4/4，拿到了 key/url/svg）
// · test/t526_qr_tab_test.dart       → 证明「页签逻辑对」
//                                       （无 DLL 环境 4/4，走的是失败分支）
// ```
// 两者都**没有**证明「设备端能把二维码画出来」：
// 单元测试里没有 sourin_core.dll，SourinCore.callAsync 直接抛异常，
// 界面走的是「二维码获取失败」那条路。
//
// 本探针在 **真窗口 + 真 DLL + 真网络** 下把二维码画出来并截图，
// 事后由 python cv2.QRCodeDetector 从截图里 **解码** 它 ——
// 把「渲染了」升级成「扫得出来」。
//
// # 用法
//
// ```text
// flutter build windows --release -t lib/t526_qr_probe.dart \
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\t526data"
// build\windows\x64\runner\Release\sourin_spike.exe
// ```
//
// # 两个必须先做的前置（否则探针只会打印「获取失败」）
//
// ```text
// ① 隔离目录里要有**部署版** bilibili.js（63,437 B，带 qrLoginStart/qrLoginPoll）
//    —— Rust 侧只 include_str! 释放 demo / iptv / tvbox-live 三个，
//       bilibili.js 历来是**人工放**的（见 state.rs:811-813 的注释）
// ② build\windows\x64\runner\Release\sourin_core.dll 必须是**新**的
//    —— flutter build windows **不重建也不同步**这个 DLL（CMake 里没有拷贝规则），
//       手工复制 rust\sourin_core\target\release\sourin_core.dll 过去
// ```

import 'dart:io';
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
import 'ui/widgets/provider_login_panel.dart';
import 'ui/widgets/qr_view.dart';

// ═══════════════════════════════════════════════════════════════════════
//  产物路径
// ═══════════════════════════════════════════════════════════════════════

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';
const String _logPath = '$_outDir\\t526-qr-probe.txt';

// ═══════════════════════════════════════════════════════════════════════
//  计数 / 日志
// ═══════════════════════════════════════════════════════════════════════

int pass = 0;
int fail = 0;
final List<String> _log = <String>[];

void say(String s) {
  _log.add(s);
  debugPrint('[T526] $s');
}

void note(String s) => say('·  $s');

void ok(String line, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  say('${cond ? '✓' : '✗'} $line   $extra');
}

Future<Never> finish(int code) async {
  final f = File(_logPath);
  f.writeAsStringSync('${_log.join('\n')}\n');
  debugPrint('[T526] 产物 = ${f.path}  ${f.lengthSync()} B');
  debugPrint('[T526] RESULT verdict=${fail == 0 ? 'PASS' : 'FAIL'} pass=$pass fail=$fail');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  隔离数据目录（硬闸）
// ═══════════════════════════════════════════════════════════════════════

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    stderr.writeln('[T526] 缺 --dart-define=DATA_DIR_OVERRIDE，拒绝启动（防止写用户库）');
    exit(3);
  }
  if (!override.toLowerCase().contains('.probe')) {
    stderr.writeln('[T526] DATA_DIR_OVERRIDE 不是隔离目录：$override');
    exit(3);
  }
  await Directory(override).create(recursive: true);
  return override;
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树工具（照抄 lib/t92_preset_probe.dart，逐条都是踩过的坑）
// ═══════════════════════════════════════════════════════════════════════

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

int countWidget(Element root, bool Function(Widget w) test) {
  int n = 0;
  void walk(Element e) {
    if (test(e.widget)) n++;
    e.visitChildren(walk);
  }

  walk(root);
  return n;
}

/// 从 [e] 往上找第一个满足 [test] 的祖先元素。
Element? ancestorWhere(Element? e, bool Function(Widget w) test) {
  Element? found;
  e?.visitAncestorElements((a) {
    if (test(a.widget)) {
      found = a;
      return false;
    }
    return true;
  });
  return found;
}

/// dart:ui 的 Rect **没有覆写 toString()**，直接插值只会打出
/// Instance of 'Rect' —— 一律走这个。
String rectStr(Rect? r) {
  if (r == null) return 'null';
  return '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)})-'
      '(${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}) '
      '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';
}

Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 事件
// ═══════════════════════════════════════════════════════════════════════

/// 必须带 timeout —— 没人请求帧时 endOfFrame 会**静默挂住**。
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
  if (!cond() && label.isNotEmpty) note('waitUntil 超时: $label');
  return cond();
}

Future<void> tapAt(Offset globalPos) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final binding = GestureBinding.instance;
  binding.handlePointerEvent(PointerDownEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
    viewId: view.viewId,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  binding.handlePointerEvent(PointerUpEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
    viewId: view.viewId,
  ));
}

/// onTap 要等过 kDoubleTapTimeout(300ms)，所以多等 700ms。
Future<void> tapAndSettle(Offset globalPos) async {
  await tapAt(globalPos);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpFrame();
}

// ═══════════════════════════════════════════════════════════════════════
//  截图
// ═══════════════════════════════════════════════════════════════════════

final GlobalKey _rootKey = GlobalKey();

class Shot {
  Shot(this.path, this.w, this.h, this.bytes, this.colors);
  final String path;
  final int w;
  final int h;
  final int bytes;
  final int colors;
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
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  if (bd == null || png == null) throw StateError('toByteData 返回 null');
  final bytes = png.buffer.asUint8List();
  final raw = bd.buffer.asUint8List();
  final path = '$_outDir\\t526-qr-probe-$name.png';
  File(path).writeAsBytesSync(bytes, flush: true);

  // 每 7 像素采样一次颜色数 —— 「截图非退化」的判据
  final set = <int>{};
  for (int i = 0; i + 3 < raw.length; i += 4 * 7) {
    set.add((raw[i] << 16) | (raw[i + 1] << 8) | raw[i + 2]);
  }
  return Shot(path, img.width, img.height, bytes.length, set.length);
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Device.init();
  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  AppTheme.setMode(AppThemeMode.light);

  String? coreError;
  try {
    final r = await SourinCore.startAsync(dir);
    say('核心启动 = $r');
  } catch (e) {
    coreError = e.toString();
    say('核心启动失败 = $coreError');
  }

  try {
    await LiquidGlassWidgets.initialize();
  } catch (e) {
    note('LiquidGlassWidgets.initialize 失败（继续）: $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: '源影 · t526 扫码取证',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));

  try {
    await _body(dir);
  } catch (e, st) {
    ok('★ 探针异常逃出（这本身是缺陷）', false, '$e');
    say('$st');
    await finish(1);
  }
}

Future<void> _body(String dir) async {
  say('──────── ⓪ 仪器自检 ────────');

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 40),
    label: 'shell 挂载',
  );
  ok('⓪ shell 已挂载', shellUp);
  if (!shellUp) {
    say('[T526] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final root0 = _rootKey.currentContext as Element?;
  ok('⓪ 根元素已挂上', root0 != null);
  if (root0 == null) await finish(1);

  ok('⓪ 数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), dir);
  ok('⓪ 隔离目录里有部署版 bilibili.js',
      File('$dir\\plugins\\bilibili.js').existsSync(),
      '$_outDir 之外的用户库一个字节都没碰');

  // ─────────────────────────────────────────────────────────────────
  //  ① 命令层（真请求）—— 与 UI 无关，先证明 DLL 真的能出二维码
  // ─────────────────────────────────────────────────────────────────
  say('──────── ① 命令层：provider_qr_login_start 真请求 ────────');

  Map<String, dynamic> start = <String, dynamic>{};
  String startErr = '';
  try {
    start = await SourinApi.providerQrLoginStart('bilibili');
  } catch (e) {
    startErr = '$e';
  }
  ok('① provider_qr_login_start 返回成功', startErr.isEmpty, startErr);
  final key = (start['key'] as String?) ?? '';
  final url = (start['url'] as String?) ?? '';
  final svg = (start['svg'] as String?) ?? '';
  final hint = (start['hint'] as String?) ?? '';
  note('key len=${key.length}  url len=${url.length}  svg len=${svg.length}');
  note('hint = $hint');
  ok('① key 非空（B站 qrcode_key 为 32 位十六进制）',
      key.length == 32, 'len=${key.length}');
  ok('① url 是 https 且带 qrcode_key=<key>',
      url.startsWith('https://') && url.contains('qrcode_key=') && url.contains(key),
      url.length > 80 ? '${url.substring(0, 80)}…' : url);
  ok('① svg 非空（Rust 侧 qr_svg_for 真的生成了二维码）',
      svg.isNotEmpty, 'len=${svg.length}');

  final parsed = parseQrSvg(svg);
  ok('① svg 能被 QrView 的解析器解开（不是只有个空壳）',
      parsed != null && parsed.isValid,
      parsed == null ? 'parse 返回 null' : 'size=${parsed.size} modules=${parsed.modules.length}');
  if (parsed != null) {
    note('svg 模块数 = ${parsed.modules.length}  dark=0x'
        '${parsed.dark.toARGB32().toRadixString(16)} light=0x'
        '${parsed.light.toARGB32().toRadixString(16)}');
    ok('① 模块数 > 100（真二维码的量级，不是退化图形）',
        parsed.modules.length > 100);
    ok('① 浅色底是纯白（qrcode crate 的 quiet zone 底色）',
        parsed.light.toARGB32() == 0xFFFFFFFF);
  }

  // ─────────────────────────────────────────────────────────────────
  //  ② UI：真的把二维码画到窗口里
  // ─────────────────────────────────────────────────────────────────
  say('──────── ② UI：设置页 → JS 插件 → B站 登录面板 ────────');

  ok('⓪ 开局没有任何 AlertDialog',
      countWidget(root0, (w) => w is AlertDialog) == 0);

  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 1400));
  await pumpFrame();

  final headUp = await waitUntil(
    () => findText(root0, '内容源、网络与同步') != null,
    timeout: const Duration(seconds: 30),
    label: '设置页页头',
  );
  ok('② 设置页已渲染', headUp);

  final settingsEl = findWidget(root0, (w) => w is SettingsPage);
  ok('② 找到 SettingsPage 元素', settingsEl != null);
  if (settingsEl == null) await finish(1);

  // 一级页 → 二级页「JS 插件」（B站 的卡片在二级页里）
  Element? entryFinder() => findText(settingsEl, 'JS 插件');
  var entryEl = entryFinder();
  if (entryEl != null) {
    try {
      await Scrollable.ensureVisible(entryEl,
          alignment: 0.5, duration: Duration.zero);
      await pumpFrame();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pumpFrame();
    } catch (e) {
      note('ensureVisible 失败（继续）: $e');
    }
    entryEl = entryFinder();
  }
  final entryRect = rectOf(entryEl);
  note('「JS 插件」入口行 rect = ${rectStr(entryRect)}');
  ok('② 找到「JS 插件」入口行', entryRect != null);
  if (entryRect == null) await finish(1);

  await tapAndSettle(entryRect.center);
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpFrame();

  final panelUp = await waitUntil(
    () => findWidget(root0,
            (w) => w is ProviderLoginPanel && w.providerId == 'bilibili') !=
        null,
    timeout: const Duration(seconds: 25),
    label: 'B站 登录面板',
  );
  ok('② 二级页里出现 B站 的 ProviderLoginPanel', panelUp);
  if (!panelUp) await finish(1);

  var panelEl = findWidget(
      root0, (w) => w is ProviderLoginPanel && w.providerId == 'bilibili');
  ok('② 面板显示「游客可用」（loginSupported=true / 未登录）',
      findText(panelEl!, '游客可用') != null);
  ok('② 展开前没有扫码页签（页签只在展开后渲染）',
      findText(panelEl, '扫码登录') == null);

  // 把面板滚进可视区，再点「登录」
  try {
    await Scrollable.ensureVisible(panelEl,
        alignment: 0.35, duration: Duration.zero);
    await pumpFrame();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await pumpFrame();
  } catch (e) {
    note('ensureVisible(panel) 失败（继续）: $e');
  }
  panelEl = findWidget(
      root0, (w) => w is ProviderLoginPanel && w.providerId == 'bilibili');

  final loginTextEl = findText(panelEl!, '登录');
  final loginRect = rectOf(loginTextEl);
  note('「登录」按钮 rect = ${rectStr(loginRect)}');
  ok('② 找到「登录」按钮', loginRect != null);
  if (loginRect == null) await finish(1);

  await tapAndSettle(loginRect.center);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await pumpFrame();

  ok('② 点开后按钮变成「收起」',
      findText(panelEl, '收起') != null);
  ok('② 出现页签行「扫码登录」',
      findText(panelEl, '扫码登录') != null);
  ok('② 出现页签行「其它方式」',
      findText(panelEl, '其它方式') != null);

  // 等二维码真的画出来（面板默认落在扫码页签，且会自动拉一次）
  final qrUp = await waitUntil(
    () => findWidget(panelEl!, (w) => w is QrView) != null,
    timeout: const Duration(seconds: 30),
    label: '二维码渲染',
  );
  ok('② 二维码已渲染（QrView 进了元素树）', qrUp);

  ok('② 没有落进「二维码不可用」兜底',
      findText(panelEl, '二维码不可用') == null);
  ok('② 没有落进「二维码获取失败」分支',
      findText(panelEl, '二维码获取失败，请重试切换到「其它方式」。') == null);

  final qrEl = findWidget(panelEl, (w) => w is QrView);
  final qrRect = rectOf(qrEl);
  note('QrView rect = ${rectStr(qrRect)}');
  ok('② QrView 尺寸 = 184x184（面板里写死的 size: 184）',
      qrRect != null &&
          (qrRect.width - 184).abs() < 1.0 &&
          (qrRect.height - 184).abs() < 1.0,
      rectStr(qrRect));

  final boxEl = ancestorWhere(qrEl, (w) => w is Container);
  final boxRect = rectOf(boxEl);
  Color? boxColor;
  final bw = boxEl?.widget;
  if (bw is Container) {
    final dec = bw.decoration;
    if (dec is BoxDecoration) boxColor = dec.color;
  }
  note('白底容器 rect = ${rectStr(boxRect)}  color = $boxColor');
  ok('② 二维码外面是 200x200 的白底容器',
      boxRect != null &&
          (boxRect.width - 200).abs() < 1.0 &&
          (boxRect.height - 200).abs() < 1.0,
      rectStr(boxRect));
  ok('② 白底容器颜色是纯白（原版注释：不加白底扫不出来）',
      boxColor == Colors.white, '$boxColor');

  // ─────────────────────────────────────────────────────────────────
  //  ②b 轮询真的在跑：等 B站 把这张码判过期（真实 ≈180 s）
  //
  //  这是**唯一**能证明「Timer 真的在按 2 秒一次打 poll 接口」的判据：
  //  t525 只证明了「刚申请完的那一次 poll 返回 pending」，证明不了轮询在跑。
  //  B站 的码约 180 秒失效（实测 179.9 s，见 .probe 里的 t527_expire.txt），
  //  所以这一段必须真等 —— 没有别的捷径。
  // ─────────────────────────────────────────────────────────────────
  say('──────── ②b 等二维码自然过期（真轮询，≈180 s） ────────');

  final qrW0 = findWidget(panelEl, (w) => w is QrView)?.widget;
  final svgBefore = qrW0 is QrView ? qrW0.svg : '';
  ok('②b 过期前拿到了二维码 svg 文本（用于比对是否换了一张新码）',
      svgBefore.isNotEmpty, 'len=${svgBefore.length}');

  final tExp0 = DateTime.now();
  final expiredUp = await waitUntil(
    () => findTextContains(panelEl!, '失效') != null,
    timeout: const Duration(seconds: 300),
    label: '二维码过期（真轮询）',
  );
  final waitedS = DateTime.now().difference(tExp0).inSeconds;
  ok('②b 轮询真的在跑：等到了「二维码已失效」（真请求，≈180 s）',
      expiredUp, '等待 ${waitedS}s');

  final expEl = findTextContains(panelEl, '失效');
  final expWidget = expEl?.widget;
  final expText = expWidget is Text ? (expWidget.data ?? '') : '';
  note('失效文案 = $expText');

  ok('②b 失效后出现「重新获取二维码」按钮',
      findText(panelEl, '重新获取二维码') != null);
  ok('②b 失效后不再显示「等待扫码」',
      findTextContains(panelEl, '等待扫码') == null);

  // 失效态截图（交付文档要一张能看见「二维码已失效 + 重新获取二维码」的图）
  final retryEl0 = findText(panelEl, '重新获取二维码');
  if (retryEl0 != null) {
    try {
      await Scrollable.ensureVisible(retryEl0,
          alignment: 0.85, duration: Duration.zero);
      await pumpFrame();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await pumpFrame();
    } catch (e) {
      note('ensureVisible(重新获取) 失败（继续）: $e');
    }
  }
  final se = await shoot('expired');
  note('失效态截图 = ${se.path}  ${se.w}x${se.h}  ${se.bytes} B');
  ok('②b 失效态截图非退化（采样颜色数 > 30）', se.colors > 30,
      'colors=${se.colors}');

  // 点「重新获取二维码」⇒ 必须换一张新码（证明真的重新申请了）
  final retryRect = rectOf(findText(panelEl, '重新获取二维码'));
  if (retryRect != null) {
    await tapAndSettle(retryRect.center);
    final up2 = await waitUntil(
      () => findWidget(panelEl!, (w) => w is QrView) != null,
      timeout: const Duration(seconds: 30),
      label: '重新获取后的二维码',
    );
    ok('②b 点「重新获取二维码」后重新画出了二维码', up2);
    final qrW1 = findWidget(panelEl, (w) => w is QrView)?.widget;
    final svgAfter = qrW1 is QrView ? qrW1.svg : '';
    ok('②b 重新获取换了一张新码（svg 与失效前逐字符不同）',
        svgAfter.isNotEmpty && svgAfter != svgBefore,
        'before=${svgBefore.length} after=${svgAfter.length}');
    ok('②b 重新获取后「重新获取二维码」按钮消失（回到等待扫码）',
        findText(panelEl, '重新获取二维码') == null);
  } else {
    ok('②b 找到「重新获取二维码」按钮（上面两条的判据点）', false);
  }

  // 页签能切回去（「其它方式」= 原来的表单）
  // ★ 先滚回页签行：②b 为了截失效态把面板往下滚过，页签行可能已经出屏
  final formTabEl = findText(panelEl, '其它方式');
  if (formTabEl != null) {
    try {
      await Scrollable.ensureVisible(formTabEl,
          alignment: 0.2, duration: Duration.zero);
      await pumpFrame();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pumpFrame();
    } catch (e) {
      note('ensureVisible(其它方式) 失败（继续）: $e');
    }
  }
  final formTabRect = rectOf(findText(panelEl, '其它方式'));
  if (formTabRect != null) {
    await tapAndSettle(formTabRect.center);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pumpFrame();
    panelEl = findWidget(
        root0, (w) => w is ProviderLoginPanel && w.providerId == 'bilibili');
    ok('② 切到「其它方式」后出现账号/Cookie 表单（TextField）',
        countWidget(panelEl!, (w) => w is TextField) > 0,
        'TextField 数 = ${countWidget(panelEl, (w) => w is TextField)}');
    // 切回扫码页签，让截图里有二维码
    final qrTabRect = rectOf(findText(panelEl, '扫码登录'));
    if (qrTabRect != null) {
      await tapAndSettle(qrTabRect.center);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpFrame();
    }
  }
  panelEl = findWidget(
      root0, (w) => w is ProviderLoginPanel && w.providerId == 'bilibili');

  // ─────────────────────────────────────────────────────────────────
  //  ③ 截图（python 侧会裁剪 + cv2 解码）
  // ─────────────────────────────────────────────────────────────────
  say('──────── ③ 截图取证 ────────');

  // ★ 把二维码滚进可视区再截图（②b / ②c 动过滚动位置）
  final qrPre = findWidget(panelEl!, (w) => w is QrView);
  if (qrPre != null) {
    try {
      await Scrollable.ensureVisible(qrPre,
          alignment: 0.5, duration: Duration.zero);
      await pumpFrame();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pumpFrame();
    } catch (e) {
      note('ensureVisible(QrView) 失败（继续）: $e');
    }
  }
  final qrEl2 = findWidget(panelEl, (w) => w is QrView);
  final qrRect2 = rectOf(qrEl2);
  ok('③ 截图前二维码仍在（QrView 没有在切页签时消失）', qrRect2 != null);
  if (qrRect2 != null) {
    say('CROPQR x=${qrRect2.left.toStringAsFixed(1)} '
        'y=${qrRect2.top.toStringAsFixed(1)} '
        'w=${qrRect2.width.toStringAsFixed(1)} '
        'h=${qrRect2.height.toStringAsFixed(1)}');
  }

  final s = await shoot('panel');
  note('截图 = ${s.path}  ${s.w}x${s.h}  ${s.bytes} B  采样颜色数=${s.colors}');
  ok('③ 截图非退化（采样颜色数 > 30）', s.colors > 30, 'colors=${s.colors}');
  ok('③ 截图尺寸 = 窗口尺寸 1280x800',
      s.w == 1280 && s.h == 800, '${s.w}x${s.h}');

  say('──────── 收尾 ────────');
  say('[T526] 命令层 key 前缀 = ${key.isEmpty ? '(空)' : key.substring(0, 8)}');
  await finish(fail == 0 ? 0 : 1);
}
