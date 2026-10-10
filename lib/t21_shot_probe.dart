// ignore_for_file: prefer_interpolation_to_compose_strings
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: prefer_const_declarations
// 说明：本文件是**探针**（临时验收工具，不属于交付 UI）。为了用脚本安全落盘，
//       字符串一律用 'a' + x.toString() 拼接、不写 Dart 插值，因此关掉上面三条
//       纯风格 lint；逻辑与判据本身没有任何抑制。
// ======================================================================
//  t21 probe -- task-21 P1-30 「视频截图」 Windows 真机取证
// ======================================================================
//
// # 为什么必须真机（widget 测试证明不了这一条）
//
// ```text
// widget 测试里**不能点**截图：media_kit 的 `Player.screenshot()` 第一句就
// `await waitForPlayerInitialization`，而那个 completer 只在 mpv 的
// `idle-active` 属性事件里 complete（media_kit-1.2.6 real.dart:1379-1385）。
// flutter_tester 里没有真实视频输出 ⇒ 这个 await **永不返回、也不抛异常**
// ⇒ 只会把用例挂住（不是失败，是挂住）。
// ⇒ 所以 test/t63_shot_ui_test.dart 只断言「入口在 + S 键计数 +1」，
//   「真的写出了一张 JPEG」只能在这个真进程里证。
// ```
//
// # 判据（三条，全是数值 —— 见 .probe/yamby/PLAN.md 的 ⑧⑨⑩⑪ 与 Windows 取证段）
//
// ```text
// ① <DATA_DIR_OVERRIDE>/shots/shot-*.jpg 至少 1 个，且 Length > 10240
// ② 该文件头 3 字节 == ff d8 ff（JPEG 魔数）
// ③ <DATA_DIR_OVERRIDE>/logs/sourin-*.log 里出现**新**的一行含 '截图 '，
//    且该行同时含绝对路径与字节数
// ```
//
// # 运行方式（必须 --debug + 隔离数据目录）
//
// ```text
// flutter build windows --debug -t lib/t21_shot_probe.dart
//   --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/yamby/t21data
// ```
//
// ⚠️ 不能省 `--debug`：`--release` 会覆盖**共享**的
//    `build/windows/x64/runner/Release/data/app.so`
//    （`windows/CMakeLists.txt:158-161` 的 `CONFIGURATIONS Profile;Release`
//     证明 Debug 不装 app.so ⇒ Debug 构建不会碰 Release 产物）。
// ⚠️ 不能省 `DATA_DIR_OVERRIDE`：本探针挂的是**真** PlayerPage，
//    没有隔离目录就会往真实用户库 %APPDATA%/app.sourin.player 写播放进度。
//
// # 两种模式（同一个 exe，用**环境变量**选，不用重编）
//
// ```text
// T21_MODE=post（默认）：先起播、等播放推进，再按 S ⇒ 成功路径（三条判据）
// T21_MODE=pre         ：**不起播**就按 S ⇒ 诚实失败路径
//                        （预期 '截图失败：还没有画面'；该调用可能永不返回，
//                          所以本模式允许被 runner 超时杀掉 —— 产物是**增量**写的）
// ```
//
// # 为什么把「还没画面就按 S」单独放一个模式
//
// ```text
// `_takeScreenshot()` 里有 `if (_shotBusy) return;`（player_page.dart:3343）。
// 若在 mpv 初始化**之前**按 S 而那个 await 永不返回，`_shotBusy` 会**永远为真**
// ⇒ 后面真正的成功路径会被这一句静默吃掉（读数变成 0，与「功能没做」一模一样）。
// ⇒ 失败路径与成功路径**必须分成两次运行**，否则仪器自己把主证据毁掉。
// ```
//
// # 为什么键盘注入走 `PlatformDispatcher.onKeyData`
//
// ```text
// 生产链路的**入口**就是它：
//   services/binding.dart:98  platformDispatcher.onKeyData = _keyEventManager.handleKeyData
//   hardware_keyboard.dart:1109  _eventFromData(data) ⇒ KeyDownEvent
//   hardware_keyboard.dart:1118  _hardwareKeyboard.handleKeyEvent(event)   ← addHandler
//   hardware_keyboard.dart:1119  _dispatchKeyMessage(<KeyEvent>[event], null)
//   focus_manager.dart:2139      keyMessageHandler = FocusManager.handleKeyMessage
//                              ⇒ 焦点树 ⇒ PlayerPage 的 Focus.onKeyEvent: _onKey
//   player_page.dart:1412        FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey)
// ```
// ⇒ 注入点在生产链路的**第一环**，后面每一环都是真代码。
//   （对照：`HardwareKeyboard.handleKeyEvent` 只覆盖硬件 handler 那一段，
//     走不到焦点树，会漏掉 `_onKey` 这条真实路径。）
//
// ⚠️ `synthesized: true` 是**必须**的：
//    `hardware_keyboard.dart:1110-1119` 只有「synthesized 且队列空」时才**立刻**
//    派发；否则事件被攒进 `_keyEventsSinceLastMessage`，等下一个原生 RawKeyEvent
//    才一起发 —— 探针里没有原生事件 ⇒ 键会**静默丢失**。
//
// # 为什么顶栏是黑的 / 底栏可能不在
//
// ```text
// 探针用 provider 'probe'（不存在的 provider）⇒ `_load()` 必失败 ⇒ `_error != null`
//   ⇒ player_page.dart:7878-7946 的底栏门控含 `_error == null` ⇒ **整条底栏不画**；
//     顶部栏（:6796）只看 `_controlsVisible`、不看 `_error` ⇒ 顶栏在。
// ⇒ 底栏截图按钮这条路径在本进程里**可能不可达** —— 探针把它当**观测**记录，
//   不作为判据（键 S 路径不受 `_error` 影响：`_onKey` 没有 `_error` 门控）。
// ```
//
// # 为什么 provider 用 'probe' 而不是真 provider
//
// ```text
// 真 provider 会走网络/登录 ⇒ 读数取决于账号与网络，不可复现；
// 而本任务要证的只有一件事：**按 S 能落一张真 JPEG**。
// 起播用 debugPlayerStartPlaybackForProbe（生产 `_startPlayback` + 本地文件）。
// ```

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'ui/app_scaffold.dart';
import 'ui/app_theme.dart';

// ======================================================================
//  常量 / 全局
// ======================================================================

/// 探针媒体：40 秒 4:3 640x480 15fps 无音轨（t513 用的同一份）
///
/// ★ 为什么**不是** task-14 的 `.probe\t14\fps_test.mp4`（80937 B）
///   实测（2026-10-05 00:20，`t21p-shot-post` 首轮）：那个夹具起播**即播完**
///   （stdout 紧邻一行 `[PLAYER] 播放结束（endAction=autoNext）`），于是
///   `debugPlayerPositionSeconds()` 恒为 `0.0`、`isPlaying` 恒为 `false`
///   ⇒ 两条阳性对照 FAIL（`position=0.0`）。当时截图其实**成功了**
///   （写出 1716545 B 的 1080x2400 JPEG —— 源视频就是那个尺寸），但
///   「静止画面也能截」与「正在播的画面能截」是两件事，阳性对照必须站得住。
///   ⇒ 换成 214740 B / 40 秒的 `.probe\t465_43.mp4`：实测 `position=0.6s`、
///     `isPlaying=true`、写出 640x480 / 140323 B 的 JPEG（与源分辨率一致）。
const kProbeMedia = String.fromEnvironment('PROBE_MEDIA',
    defaultValue: r'D:\WishProject\sourin-flutter-spike\.probe\t465_43.mp4');

/// 产物目录（result.txt + 截图证据）
const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe\yamby';

final _rootKey = GlobalKey();

int pass = 0;
int fail = 0;
int skipped = 0;

final List<String> _logLines = <String>[];

void say(String s) {
  final line = '[T21S] ' + s;
  _logLines.add(line);
  // ignore: avoid_print
  print(line);
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  final tag = cond ? 'OK  ' : 'FAIL';
  final tail = extra.isEmpty ? '' : '  ' + extra;
  final line = '[T21S] ' + tag + ' ' + label + tail;
  _logLines.add(line);
  // ignore: avoid_print
  print(line);
}

/// 只打印、不计分（观测到的现象，不是判据）
void note(String s) => say('  . ' + s);

/// 仪器失败 ⇒ 这一段**不产出结论**
///
/// ★ 为什么不并进 fail：fail 的语义是「产品没通过判据」，而这里是
///   「我自己的仪器不可信」。历史踩过：注入器没送到 ⇒ 读数 0，与
///   「功能没实现 ⇒ 读数 0」**一模一样**。两者混进一个计数器，后来的人
///   就分不清「功能坏了」和「压根没测成」。
void skip(String why) {
  skipped++;
  say('⊘ 未评估（仪器/环境限制，**不是**产品结论）: ' + why);
}

// ======================================================================
//  落盘（增量写，允许被超时杀掉）
// ======================================================================

String _artifactPath() => _outDir + '\\t21p-shot.txt';

void flush(String stage) {
  final body = StringBuffer()
    ..writeln('TAG t21p-shot')
    ..writeln('STAGE ' + stage)
    ..writeln('MODE ' + mode)
    ..writeln('RESULT pass=' + pass.toString() +
        ' fail=' + fail.toString() + ' skipped=' + skipped.toString())
    ..writeln('---')
    ..write(_logLines.join(Platform.lineTerminator));
  try {
    File(_artifactPath()).writeAsStringSync(body.toString());
  } catch (e) {
    say('!! 产物写盘失败: ' + e.toString());
  }
}

Future<Never> finish(int code) async {
  /*
   * ★ 退出码把 skipped 也算进去
   *
   * 若只写 fail == 0，一次「某段没测成」的运行会以 0 退出，
   * 读的人只看退出码就会当成全绿。而事实是那一段**没产出结论**。
   */
  final effective = (fail > 0 || skipped > 0) ? 1 : code;
  flush('final');
  say('ARTIFACT ' + _artifactPath());
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(effective);
}

// ======================================================================
//  仪器：目录 / 文件 / 帧 / 键 / 指针
// ======================================================================

String get mode {
  final m = Platform.environment['T21_MODE'] ?? 'post';
  return m.isEmpty ? 'post' : m;
}

Future<String> resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    say('!! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    say('   本探针挂的是**真** PlayerPage，没有隔离目录就会往');
    say('   真实用户库 %APPDATA%/app.sourin.player 写播放进度。');
    say('   正确命令：');
    say('     flutter build windows --debug -t lib/t21_shot_probe.dart');
    say('       --dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/yamby/t21data');
    exit(3);
  }
  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

Directory shotsDirOf(String dataDir) =>
    Directory(dataDir + Platform.pathSeparator + 'shots');

Directory logsDirOf(String dataDir) =>
    Directory(dataDir + Platform.pathSeparator + 'logs');

List<File> shotFiles(String dataDir) {
  final d = shotsDirOf(dataDir);
  if (!d.existsSync()) return const <File>[];
  final out = <File>[];
  for (final e in d.listSync(followLinks: false)) {
    if (e is File && e.path.endsWith('.jpg')) out.add(e);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// 日志里含 '截图 ' 的行（`AppLog.write('DL', '截图 ...')` 的出口）
///
/// ★ 判据只认**磁盘文件**：`AppLog._append` 是异步的（app_log.dart:200-219），
///   内存里的 `AppLog.lines` 可能在落盘前就有、也可能落盘失败；
///   而用户真正能拿到的是文件。
List<String> shotLogLines(String dataDir) {
  final d = logsDirOf(dataDir);
  if (!d.existsSync()) return const <String>[];
  final out = <String>[];
  for (final e in d.listSync(followLinks: false)) {
    if (e is! File || !e.path.endsWith('.log')) continue;
    List<String> lines;
    try {
      lines = e.readAsLinesSync();
    } catch (_) {
      continue;
    }
    for (final l in lines) {
      if (l.contains('截图 ')) out.add(l);
    }
  }
  return out;
}

/// 文件头 3 字节的十六进制（小写、无分隔）
String head3Hex(File f) {
  final raf = f.openSync();
  try {
    final b = Uint8List(3);
    final n = raf.readIntoSync(b);
    if (n < 3) return 'short(' + n.toString() + ')';
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  } finally {
    raf.closeSync();
  }
}

Future<void> pumpFrame() async {
  final b = SchedulerBinding.instance;
  b.scheduleFrame();
  // ★ 必须带超时：没有帧回调时 endOfFrame 会**静默挂住**整个探针
  await b.endOfFrame.timeout(const Duration(milliseconds: 2000),
      onTimeout: () {});
}

Future<void> settle([int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await pumpFrame();
  }
}

Future<bool> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 20), String label = ''}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  say('  ⏱ 等超时: ' + label + '（' + timeout.inSeconds.toString() + 's）');
  return false;
}

Element? _findFirst(Element root, bool Function(Widget) test) {
  Element? found;
  void walk(Element e) {
    if (found != null) return;
    if (test(e.widget)) {
      found = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return found;
}

Offset? centerOf(Element? e) {
  final ro = e?.renderObject;
  if (ro is RenderBox && ro.hasSize) {
    return ro.localToGlobal(ro.size.center(Offset.zero));
  }
  return null;
}

/// 进程内指针注入 —— 走**生产**那条路
///
/// `GestureBinding.handlePointerEvent` 就是平台层收到原生鼠标消息后调用的
/// 那一个函数（先例：lib/delivery_test.dart:1666-1743 的 _tapAt）。
Future<void> tapAt(Offset pos, String label) async {
  const pointer = 21;
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pointer, position: pos, kind: PointerDeviceKind.mouse));
  await Future<void>.delayed(const Duration(milliseconds: 600));
  note('指针注入 ' + label + ' @ ' + pos.toString());
}

/// 键盘注入 —— 从生产链路的**第一环**进去（见文件头）
Future<bool> injectKeyDownUp(LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical, String label) async {
  final pd = WidgetsBinding.instance.platformDispatcher;
  final cb = pd.onKeyData;
  if (cb == null) {
    say('!! onKeyData 为空 ⇒ 键注入不可能送达（仪器失败）');
    return false;
  }
  final t0 = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch % 100000);
  final down = ui.KeyData(
      timeStamp: t0,
      type: ui.KeyEventType.down,
      physical: physical.usbHidUsage,
      logical: logical.keyId,
      character: null,
      synthesized: true);
  final h1 = cb(down);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  final up = ui.KeyData(
      timeStamp: t0 + const Duration(milliseconds: 60),
      type: ui.KeyEventType.up,
      physical: physical.usbHidUsage,
      logical: logical.keyId,
      character: null,
      synthesized: true);
  final h2 = cb(up);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  note('键注入 ' + label + '：onKeyData 返回 down=' +
      h1.toString() + ' up=' + h2.toString());
  return true;
}

// ======================================================================
//  main
// ======================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★ media_kit 必须在 runApp 之前（`lib/shell.dart:276` 的同一条，
   *   那里记录了「漏了它 ⇒ 播放器根本起不来」的事故）。
   */
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File(
        Directory.current.path + Platform.pathSeparator + 'libmpv-2.dll');
    say('默认初始化失败: ' + e.toString());
    say('  → 退回显式 DLL: ' + dll.path +
        ' (存在=' + dll.existsSync().toString() + ')');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  final dataDir = await resolveDataDir();
  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    say('UiPrefs.load 失败（忽略）: ' + e.toString());
  }
  try {
    final r = await SourinCore.startAsync(dataDir);
    say('核心: ' + r.toString());
  } catch (e) {
    say('SourinCore.startAsync 失败（忽略）: ' + e.toString());
  }

  say('数据目录: ' + dataDir);
  say('模式: ' + mode);
  say('探针媒体: ' + kProbeMedia +
      ' (存在=' + File(kProbeMedia).existsSync().toString() + ')');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-21 P1-30 截图探针');
  }

  final theme = AppTheme.themeFor(Brightness.light);
  final materialTheme = AppTheme.themeFor(Brightness.light);

  runApp(RepaintBoundary(
    key: _rootKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
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
      home: const PlayerPage(
        provider: 'probe',
        id: 'probe',
        title: 'task-21 P1-30 截图探针',
        liveChannelId: 'probe-ch',
        onLiveChannels: onLiveChannelsProbe,
      ),
    ),
  ));

  await Future<void>.delayed(const Duration(milliseconds: 900));

  try {
    await body(dataDir);
  } catch (e, st) {
    say('!! 探针异常: ' + e.toString());
    say(st.toString());
    flush('exception');
    await finish(4);
  }
  await finish(0);
}

({List<LiveChannel> channels, int index})? onLiveChannelsProbe() =>
    (channels: const <LiveChannel>[], index: 0);

// ======================================================================
//  主流程
// ======================================================================

Future<void> body(String dataDir) async {
  say('');
  say('── ⓪ 仪器自检 ──');

  final root = _rootKey.currentContext as Element?;
  ok('根元素已挂上（_rootKey 有 context）', root != null);
  if (root == null) {
    say('★ 整棵 UI 没挂上 ⇒ 后续全部无意义，中止');
    flush('no-root');
    await finish(1);
  }

  final pageEl = _findFirst(root, (w) => w is PlayerPage);
  ok('树上找到**真实的** PlayerPage 元素', pageEl != null,
      pageEl == null ? '' : pageEl.widget.runtimeType.toString());
  ok('平台键盘回调 onKeyData 已挂上（键注入的前提）',
      WidgetsBinding.instance.platformDispatcher.onKeyData != null);

  final baseShots = shotFiles(dataDir);
  final baseLogs = shotLogLines(dataDir);
  ok('取证前 shots/ 里没有旧 .jpg（防把陈旧产物读成新证据）',
      baseShots.isEmpty, '初始 ' + baseShots.length.toString() + ' 个');
  ok('取证前 logs/ 里没有旧「截图 」行', baseLogs.isEmpty,
      '初始 ' + baseLogs.length.toString() + ' 行');
  ok('shots 目录与 clip-cache 目录不是同一个',
      ClipDownloader.shotsDir.toString().isNotEmpty &&
          shotsDirOf(dataDir).absolute.path !=
              Directory(dataDir + Platform.pathSeparator + 'clip-cache')
                  .absolute.path);

  final btn0 = _findFirst(
      root, (w) => w is Icon && w.icon == Icons.photo_camera);
  note('底栏截图按钮当前在树上: ' + (btn0 != null).toString() +
      '（_error != null 时整条底栏不画 ⇒ 这是观测，不是判据）');
  flush('mounted');

  if (mode == 'pre') {
    await bodyPrePlayback(dataDir);
    return;
  }

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ① 真播放起播（生产 _startPlayback + 本地文件）──');
  // ────────────────────────────────────────────────────────────────
  final started = await debugPlayerStartPlaybackForProbe(kProbeMedia);
  ok('★ 走**生产** _startPlayback 起播成功', started);
  flush('started');

  final advanced = await waitUntil(
      () => (debugPlayerPositionSeconds() ?? 0) > 0.5,
      timeout: const Duration(seconds: 25),
      label: '播放推进到 0.5s');
  ok('播放真的在推进（position > 0.5s）', advanced,
      'position=' + (debugPlayerPositionSeconds() ?? -1).toString());
  ok('isPlaying == true（阳性对照：真的在播，不是静止画面）',
      debugPlayerIsPlaying() == true);
  await settle(3);

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ② 入口一：底栏相机按钮（若底栏在树上）──');
  // ────────────────────────────────────────────────────────────────
  final btn = _findFirst(
      root, (w) => w is Icon && w.icon == Icons.photo_camera);
  final tipBtn = _findFirst(
      root, (w) => w is Tooltip && w.message == '截图');
  if (btn == null || tipBtn == null) {
    skip('底栏在 _error 态下不渲染 ⇒ 按钮路径本进程不可达'
        '（键 S 路径不受 _error 影响，见 ③）');
  } else {
    final c0 = debugPlayerScreenshotCalls() ?? -1;
    final pos = centerOf(tipBtn);
    if (pos == null) {
      skip('按钮没有尺寸（RenderBox 未布局）⇒ 点不到');
    } else {
      await tapAt(pos, '底栏截图按钮');
      await settle(3);
      final c1 = debugPlayerScreenshotCalls() ?? -1;
      ok('点按钮 ⇒ debugPlayerScreenshotCalls 计数 +1',
          c1 == c0 + 1, c0.toString() + ' -> ' + c1.toString());
      final wrote = await waitUntil(
          () => shotFiles(dataDir).length > baseShots.length,
          timeout: const Duration(seconds: 25),
          label: '按钮路径写出 shot-*.jpg');
      ok('点按钮真的写出了一张 .jpg', wrote,
          '现在 ' + shotFiles(dataDir).length.toString() + ' 个');
    }
  }
  flush('after-button');

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ③ 入口二：PC 键 S（生产 _onKey 分支）──');
  // ────────────────────────────────────────────────────────────────
  final beforeS = shotFiles(dataDir).length;
  final c2 = debugPlayerScreenshotCalls() ?? -1;
  final injected = await injectKeyDownUp(
      LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS, 'S');
  ok('键注入真的送达了 onKeyData（仪器）', injected);
  await settle(2);
  final c3 = debugPlayerScreenshotCalls() ?? -1;
  ok('★ 按 S ⇒ debugPlayerScreenshotCalls 计数 +1',
      c3 == c2 + 1, c2.toString() + ' -> ' + c3.toString());
  flush('after-key');

  await waitUntil(
      () => shotFiles(dataDir).length > beforeS,
      timeout: const Duration(seconds: 30),
      label: '按 S 后 shots/ 出现新 .jpg');
  flush('after-wait');

  // ────────────────────────────────────────────────────────────────
  say('');
  say('── ④ 三条判据（数值）──');
  // ────────────────────────────────────────────────────────────────
  final files = shotFiles(dataDir);
  final fresh = <File>[];
  for (final f in files) {
    if (!baseShots.any((b) => b.path == f.path)) fresh.add(f);
  }
  ok('判据① 至少 1 个新的 shot-*.jpg', fresh.isNotEmpty,
      '新增 ' + fresh.length.toString() + ' 个 / 共 ' +
          files.length.toString() + ' 个');
  if (fresh.isEmpty) {
    say('★ 没有新文件 ⇒ 判据②③无法评估');
    skip('没有新截图文件：判据②（JPEG 魔数）与判据③（日志行）无处可查');
    note('末次提示语 _tip = ' + (debugPlayerLastTip() ?? '(null)').toString());
    flush('no-file');
    return;
  }
  final f0 = fresh.first;
  final len = f0.lengthSync();
  ok('判据① 文件大小 > 10240 字节', len > 10240,
      len.toString() + ' 字节  ' + f0.path);
  final h3 = head3Hex(f0);
  ok('判据② 文件头 3 字节 == ff d8 ff（JPEG 魔数）', h3 == 'ffd8ff', h3);
  final inData = f0.absolute.path
      .startsWith(Directory(dataDir).absolute.path);
  ok('判据① 落盘位置在隔离数据目录内（没写进用户真库）', inData,
      f0.absolute.path);

  final logs = shotLogLines(dataDir);
  final freshLogs = <String>[];
  for (final l in logs) {
    if (!baseLogs.any((b) => b == l)) freshLogs.add(l);
  }
  ok('判据③ logs/sourin-*.log 里出现**新**的「截图 」行',
      freshLogs.isNotEmpty,
      '新增 ' + freshLogs.length.toString() + ' 行 / 共 ' +
          logs.length.toString() + ' 行');
  final withPath = <String>[];
  for (final l in freshLogs) {
    if (l.contains(f0.path) && RegExp(r'\d+ 字节').hasMatch(l)) {
      withPath.add(l);
    }
  }
  ok('判据③ 该行同时含**绝对路径**与**字节数**', withPath.isNotEmpty,
      withPath.isEmpty ? '' : withPath.first);
  for (final l in freshLogs) {
    note('日志行: ' + l);
  }

  say('');
  say('── ⑤ 生产提示语（用户可见的那句）──');
  final tip = debugPlayerLastTip();
  note('_tip = ' + (tip ?? '(null)').toString());
  ok('提示语说的是「已截图 … 字节 → …」',
      tip != null && tip.contains('已截图') && tip.contains('字节'),
      tip ?? '');

  final copied = _outDir + '\\t21p-shot-' +
      DateTime.now().millisecondsSinceEpoch.toString() + '.jpg';
  try {
    f0.copySync(copied);
    say('证据副本: ' + copied + ' (' +
        File(copied).lengthSync().toString() + ' B)');
  } catch (e) {
    note('副本失败（不影响判据）: ' + e.toString());
  }
  flush('done');
}

// ======================================================================
//  T21_MODE=pre：还没画面就按 S（诚实失败路径）
// ======================================================================

Future<void> bodyPrePlayback(String dataDir) async {
  say('');
  say('── ①（pre 模式）**未起播**就按 S ──');
  say('   预期：screenshot() 返回空 ⇒ 提示「截图失败：还没有画面」');
  say('   ⚠️ 该 await 可能**永不返回**（mpv 未初始化）⇒ 本模式允许被超时杀掉，');
  say('      产物是增量写的（flush），已写下的观测不会丢。');
  final c0 = debugPlayerScreenshotCalls() ?? -1;
  final injected = await injectKeyDownUp(
      LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS, 'S(pre)');
  ok('键注入送达（仪器）', injected);
  final c1 = debugPlayerScreenshotCalls() ?? -1;
  ok('未起播时按 S 也进了 _takeScreenshot（计数 +1）',
      c1 == c0 + 1, c0.toString() + ' -> ' + c1.toString());
  flush('pre-injected');

  final settled = await waitUntil(
      () => debugPlayerLastTip() != null,
      timeout: const Duration(seconds: 12),
      label: '出现提示语');
  final tip = debugPlayerLastTip();
  note('12s 内出现提示语: ' + settled.toString() +
      '  _tip=' + (tip ?? '(null)').toString());
  ok('提示语是诚实的失败文案「截图失败：还没有画面」',
      tip != null && tip.contains('截图失败'), tip ?? '');
  final logs = shotLogLines(dataDir);
  for (final l in logs) {
    note('日志行: ' + l);
  }
  ok('失败也**没有**留下半个 .jpg（不会写坏文件）',
      shotFiles(dataDir).isEmpty,
      'shots 里 ' + shotFiles(dataDir).length.toString() + ' 个');
  flush('pre-done');
}
