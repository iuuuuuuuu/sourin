// ═══════════════════════════════════════════════════════════════════════
//  task-72【④】「播放页面感觉也卡卡的」—— **真机真播放**取证探针
//  （2026-09-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须再写一个探针（`test/t72_jank_test.dart` 已经全绿了）
//
// ④ 的读数来自**合成 tick 注入**：
// ```text
// PB 180 次 tick（位置 0s→3.0s）⇒ 改前 180 次 setState → 改后 3 次
// ```
// 那证明了**机制**（守卫真的在挡），但证不了**收益的量级** ——
// 因为「灌 180 次 tick」是**我自己造的**频率。真实的质疑是：
//
// ```text
// 「mpv 本来就只发 3 tick/秒，你把它节流成 1 次/秒，
//   省下的那 2 次 setState 根本看不见 ⇒ 修复 B 没有意义」
// ```
//
// ★ 这个质疑**只能靠真播放**回答：mpv 的 `time-pos` 事件到底多密。
//   所以本探针要拿到的核心读数是：
// ```text
// ticks      = 真实播放 N 秒内 mpv 发了多少 time-pos
// setStates  = 其中真正触发页面重建的有多少
// ```
//   `ticks == setStates` ⇒ 修复 B 无收益（我会照实报）
//   `ticks >> setStates` ⇒ 修复 B 有实际收益，且能量化
//
// # 为什么不能照抄 `t72_jank_test.dart` 的重建计数器
//
// widget 测试用的是 `debugOnRebuildDirtyWidget`。查过 Flutter 源码：
// ```text
// framework.dart:5516  void rebuild({bool force = false}) {
// framework.dart:5521      assert(() {
// framework.dart:5522        debugOnRebuildDirtyWidget?.call(this, _debugBuiltOnce);
// ```
// ★ 它在 `assert(() {...}())` **里面** ⇒ **release 构建里整段被剥掉**，
//   回调永远不会跑。⇒ 真机取证只能用别的仪器（见下面 ④-A 的 `Element.dirty`）。
//
// # ④-A 的真机仪器：`Element.dirty`
//
// ```text
// framework.dart:5335  bool get dirty => _dirty;     ← 普通 getter，无 assert
// framework.dart:5402  _dirty = true;                ← markNeedsBuild 置位
// ```
// `setState` → `markNeedsBuild` → `_dirty = true`（**同步**置位）。
// ⇒ 注入一次 hover 后**立刻**读播放页那个 `Element.dirty`，
//   就能知道这次 hover 有没有引发重建 —— release 下也可用。
//
// # ④-C 的真机仪器：探针自己传的 `onLiveChannels` 闭包计数器
//
// `onLiveChannels` 是**外部传进来的回调**（`player_page.dart:383`），
// 计数它不依赖任何框架内部机制 ⇒ release 下天然可用。
//
// # 为什么不用系统鼠标 / 为什么能自己截图
// 同 `lib/merge_view_probe.dart` 顶部那两段说明（Owner 要求不碰他的鼠标；
// `RepaintBoundary.toImage()` 在真实应用进程里正常工作）。
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/t72_playback_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t72p-data"
// ```
// ⚠️ **必须**用隔离数据目录 —— 本探针会挂**真的** `PlayerPage`，
//    它 `initState` 里会读偏好、`_load()` 会碰 FFI；绝不能指向用户真库。
//
// ⚠️ 必须从**带着 `libmpv-2.dll` 的目录**运行（复制 `build\...\Release\`）。

import 'dart:async';
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
import 'core/models.dart' show LiveChannel;
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/player_page.dart'
    show
        PlayerPage,
        debugPlayerAnySheetOpen,
        debugPlayerDurationSeconds,
        debugPlayerIsPlaying,
        debugPlayerOpenForProbe,
        debugPlayerOpenLiveChannelsForProbe,
        debugPlayerPositionSeconds,
        debugPlayerPositionSetStates,
        debugPlayerPositionTicks,
        debugPlayerPushPositionForProbe,
        debugPlayerResetPositionSetStates,
        debugPlayerSeekForProbe;
import 'ui/app_scaffold.dart';

/// 截图用的重绘边界（包住整棵 UI）
final _rootKey = GlobalKey();

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 探针媒体（编译期常量；默认用本机那份 20 秒的 HEVC 样本）
const kProbeMedia = String.fromEnvironment(
  'PROBE_MEDIA',
  defaultValue: r'D:\WishProject\sourin-flutter-spike\hevc_sample.mp4',
);

/// 全文日志 —— 每一行都进这里，由 `finish()` 落盘
///
/// ★ 为什么不能只靠 `debugPrint`：它默认是 `debugPrintThrottled`
///   （约 1 KB/秒的限速），而探针结尾 `exit()` 是**立即**终止进程
///   ⇒ 被限速缓冲住的行**会丢**。丢掉的若正好是 `RESULT` 行，
///   读数就从「跑完了」退化成「看不出跑没跑」。
///   所以每行都进 `_log`，`finish()` 先同步写盘再退出
///   （同 `lib\t92_preset_probe.dart` 已验证的做法）。
final StringBuffer _log = StringBuffer();

void _emit(String line) {
  _log.writeln(line);
  debugPrint('[T72P] $line');
}

void say(String s) => _emit(s);

int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    _emit('✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    _emit('✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

/// 只打印、不计分（用于「观测到的现象」，不是判据）
void note(String s) => _emit('· $s');

/// 仪器失败 ⇒ 这一段**不产出结论**
///
/// ★ 为什么不并进 `fail`：`fail` 的语义是「产品没通过判据」，而这里是
///   「我自己的仪器不可信」。历史踩过：注入器没送到 ⇒ 读数 0，与
///   「修复生效 ⇒ 读数 0」**一模一样**。两者混进一个计数器，后来的人
///   就分不清「功能坏了」和「压根没测成」。
/// ★ 为什么仍要让退出码非 0：`fail=0` 若夹着未评估的判据，会被误读成
///   「全绿」。所以 `finish()` 里 `skipped > 0` 也退 1。
int skipped = 0;

void skip(String why) {
  skipped++;
  _emit('⊘ 未评估（仪器失败，**不是**产品结论）: $why');
}

/// 落盘 + 退出（**唯一**的出口）
///
/// ⚠️ `exit()` 不展开 `finally`、也不等 `debugPrint` 的限速队列
///    ⇒ 必须先 `writeAsStringSync` 再 `exit`。
Future<Never> finish(int code) async {
  const path = '$_outDir\\t72p-playback.txt';
  /*
   * ★ 退出码把 `skipped` 也算进去
   *
   * 若只写 `fail == 0`，一次「④-A 没测成」的运行会以 0 退出，
   * 读的人只看退出码就会当成「全绿」。而事实是那一段**没产出结论**。
   */
  final effective = (fail > 0 || skipped > 0) ? 1 : code;
  final body = StringBuffer()
    ..writeln('TAG t72p-playback')
    ..writeln('EXIT $effective')
    ..writeln('RESULT pass=$pass fail=$fail skipped=$skipped')
    ..writeln('---')
    ..write(_log);
  try {
    File(path).writeAsStringSync(body.toString());
    debugPrint('[T72P] ARTIFACT $path (${File(path).lengthSync()} B)');
  } catch (e) {
    debugPrint('[T72P] ★ ARTIFACT 写盘失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(effective);
}

// ═══════════════════════════════════════════════════════════════════════
//  ④-C 的仪器：探针自己传进去的 `onLiveChannels` 闭包
// ═══════════════════════════════════════════════════════════════════════

int liveChannelsCalls = 0;

({List<LiveChannel> channels, int index})? onLiveChannelsProbe() {
  liveChannelsCalls++;
  return (
    channels: const [
      LiveChannel(id: 'cctv1', name: 'CCTV-1 综合', group: '央视'),
      LiveChannel(id: 'cctv2', name: 'CCTV-2 财经', group: '央视'),
      LiveChannel(id: 'hunan', name: '湖南卫视', group: '卫视'),
    ],
    index: 0,
  );
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

/// 把 `_rootKey` 那棵子树光栅化成 PNG
///
/// ★ 返回 (路径, 唯一颜色数) —— 颜色数是**仪器自检**：
///   全黑/全白图只有 1~2 色，那种图不能当证据（铁律：退化图不是证据）。
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
  final path = '$_outDir\\t72p-$name.png';
  File(path).writeAsBytesSync(data!.buffer.asUint8List());

  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  final w = img.width, h = img.height;
  img.dispose();
  say('  截图 $name: ${w}x$h  ${File(path).lengthSync()} B  '
      '采样颜色数=${seen.length}');
  return (path, seen.length);
}

// ═══════════════════════════════════════════════════════════════════════
//  元素树 / 帧 / 指针
// ═══════════════════════════════════════════════════════════════════════

/// 找树上那个**真实的** `PlayerPage` 元素（④-A 要读它的 `dirty`）
Element? findPlayerPageElement(Element root) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget is PlayerPage) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 找顶部栏元素 —— 它是 `_controlsVisible` 的**结构读数器**
///
/// ★ 为什么要靠私有类名：`player_page.dart:6796` 是
///   `if (_controlsVisible) _TopBar(...)` ⇒ **顶部栏在树上 == 控制条可见**。
///   而生产文件里**没有任何** `debugPlayer*Controls*` 读数钩子，
///   我也**不能**为了探针去改生产文件（会切断交付包 `app.so` 与源码的溯源链）。
///   `_TopBar` 是私有类，`runtimeType.toString()` 就是 `'_TopBar'`。
///
/// ★★ 这个读数器**必须**配阳性对照才可信（见 ④-A 段）：
///    单独一次「找不到 _TopBar」既可能是「控制条真的隐藏了」，
///    也可能是「选择器写错了」—— 两者的读数**完全一样**。
Element? findTopBar(Element root) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (e.widget.runtimeType.toString() == '_TopBar') {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 等一帧真的画完（真实应用进程里没有 `tester.pump()`）
///
/// ⚠️ 加超时兜底：万一没人请求帧，`endOfFrame` 会一直挂着，
///    那会让探针**静默停住**（历史踩过：只看到超时，看不到原因）。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 注入一次鼠标**悬停**（不碰系统光标）
///
/// `MouseRegion.onHover`（`player_page.dart:6429`）就是 `_showControls()`
/// 的触发源 —— ④-A 的原始症状是「鼠标一动就整页重建」。
Future<void> injectHover(Offset globalPos) async {
  WidgetsBinding.instance.handlePointerEvent(PointerHoverEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
}

/// 先发一次 `PointerAddedEvent`，让框架知道有个鼠标设备
Future<void> injectMouseAdded(Offset globalPos) async {
  WidgetsBinding.instance.handlePointerEvent(PointerAddedEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

/// 在「注入前必须干净」的前提下注入 **1 次** hover
///
/// 返回 `(前置是否干净, 注入后是否被标脏, 第几次尝试才成功)`
///
/// ★ 为什么必须"重试到前置干净"：真播放期间 `_onPositionTick` 每秒仍会
///   `setState` 一次（修复 B 只是把它从 1:1 节流到 1/秒，**没有**取消它）
///   ⇒ `PlayerPage.dirty` 随时可能**先**被别人置位。
///   若不管前置就注入，`after == true` 可能来自位置 tick 而不是 hover
///   ⇒ 对照就成了**空通过**（一个来源不明的 true 比没有对照更危险）。
Future<(bool, bool, int)> hoverOnceClean(Element el, Offset globalPos) async {
  for (var attempt = 1; attempt <= 20; attempt++) {
    await pumpFrame();
    if (el.dirty) continue; // 位置 tick 抢先 ⇒ 本次样本作废，重来
    await injectHover(globalPos);
    return (true, el.dirty, attempt);
  }
  return (false, false, 20);
}

int _pct(List<int> xs, double q) {
  if (xs.isEmpty) return 0;
  final s = <int>[...xs]..sort();
  final i = ((s.length - 1) * q).round();
  return s[i];
}

/// 等某个条件成立（带超时 + 标签）
Future<bool> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 15),
  String label = '',
}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  say('  ⏱ 等超时: $label（${timeout.inSeconds}s）');
  return false;
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * ★ media_kit 必须在 runApp 之前（`shell.dart:276` 的同一条，
   *   那里记录了"漏了它 ⇒ 播放器根本起不来"的事故）。
   */
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File(
        '${Directory.current.path}${Platform.pathSeparator}libmpv-2.dll');
    say('默认初始化失败: $e');
    say('  → 退回显式 DLL: ${dll.path} (存在=${dll.existsSync()})');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  try {
    await Device.init();
  } catch (e) {
    say('Device.init 失败（忽略，有兜底）: $e');
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  final r = await SourinCore.startAsync(dir);

  debugPrint('[T72P] ══════ task-72④ 播放页卡顿 —— 真机真播放取证 ══════');
  say('数据目录: $dir');
  say('核心: $r');
  say('探针媒体: $kProbeMedia (存在=${File(kProbeMedia).existsSync()})');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-72④ 播放探针');
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
        home: const PlayerPage(
          provider: 'probe',
          id: 'probe',
          title: 'task-72④ 播放探针',
          // 直播模式：`_isLive == true` ⇒ `_saveProgress`/`_prepareResume`
          // 都早退，合成 tick 不会往库里写进度（隔离库也干净些）
          liveChannelId: 'probe-ch',
          onLiveChannels: onLiveChannelsProbe,
        ),
      ),
    ),
  );

  await Future<void>.delayed(const Duration(milliseconds: 900));

  final root = _rootKey.currentContext as Element?;
  final pageEl = root == null ? null : findPlayerPageElement(root);

  debugPrint('[T72P]');
  debugPrint('[T72P] ── ⓪ 仪器自检 ──');
  ok('根元素已挂上', root != null);
  ok('树上找到**真实的** PlayerPage 元素', pageEl != null,
      '${pageEl?.widget.runtimeType}');
  ok('两个位置计数器初值为 0',
      debugPlayerPositionTicks == 0 && debugPlayerPositionSetStates == 0,
      'ticks=$debugPlayerPositionTicks sets=$debugPlayerPositionSetStates');

  final (_, c0) = await shoot('00-mount');
  ok('挂载截图非退化（>20 色）', c0 > 20, '颜色数=$c0');

  if (pageEl == null) {
    say('★ PlayerPage 没挂上 ⇒ 后续全部无意义，中止');
    await finish(1);
  }

  // ─────────────────────────────────────────────────────────────────
  //  ① 真播放起播
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T72P]');
  debugPrint('[T72P] ── ① 真播放起播（本地文件，不经网络/登录）──');

  final url = Uri.file(kProbeMedia).toString();
  say('open: $url');
  final opened = await debugPlayerOpenForProbe(url);
  ok('debugPlayerOpenForProbe 返回 true', opened);

  final advanced = await waitUntil(
    () => (debugPlayerPositionSeconds() ?? 0) > 0.5,
    timeout: const Duration(seconds: 20),
    label: '位置 > 0.5s',
  );
  ok('位置**真的**在推进（>0.5s）', advanced,
      'pos=${debugPlayerPositionSeconds()}');
  ok('播放中 (_playing == true)', debugPlayerIsPlaying() == true,
      'playing=${debugPlayerIsPlaying()}');

  /*
   * ★ 空判据守卫：位置不动就中止 —— 否则后面所有「tick 数」都是 0，
   *   「0 次 setState」会伪装成"修复生效"（历史踩过：
   *   在线流 unauthorized 没起播，位置永远是 0，断言全绿）。
   */
  if (!advanced) {
    say('★ 位置不动 ⇒ 本段无信息量，中止（不许把 0 当成绩）');
    await finish(1);
  }

  say('时长读数 = ${debugPlayerDurationSeconds()}s');
  final (_, c1) = await shoot('01-playing');
  ok('播放中截图非退化（>20 色）', c1 > 20, '颜色数=$c1');

  // ─────────────────────────────────────────────────────────────────
  //  ② + ③ 同一个 5 秒窗口：真 tick 速率 与 真帧耗时
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T72P]');
  debugPrint('[T72P] ── ② 真 tick 速率 vs setState（修复 B 的实际收益）──');
  debugPrint('[T72P] ── ③ 真帧耗时（Owner 说的"卡卡的"）──');

  debugPlayerResetPositionSetStates();

  final timings = <FrameTiming>[];
  void onTimings(List<FrameTiming> t) => timings.addAll(t);
  SchedulerBinding.instance.addTimingsCallback(onTimings);

  const window = Duration(seconds: 5);
  final t0 = DateTime.now();
  await Future<void>.delayed(window);
  final elapsed = DateTime.now().difference(t0);
  SchedulerBinding.instance.removeTimingsCallback(onTimings);

  final ticks = debugPlayerPositionTicks;
  final sets = debugPlayerPositionSetStates;
  final secs = elapsed.inMilliseconds / 1000.0;

  note('窗口 = ${secs.toStringAsFixed(2)}s');
  note('ticks     = $ticks   (${(ticks / secs).toStringAsFixed(2)} /秒)');
  note('setStates = $sets   (${(sets / secs).toStringAsFixed(2)} /秒)');
  note('比值 ticks/setStates = '
      '${sets == 0 ? "∞（0 次重建）" : (ticks / sets).toStringAsFixed(2)}');

  ok('② 真播放窗口内确实收到了 time-pos', ticks > 0, 'ticks=$ticks');
  ok(
    '② setState 次数 ≤ 秒数+2（节流真的在挡）',
    sets <= elapsed.inSeconds + 2,
    'sets=$sets  窗口=${elapsed.inSeconds}s',
  );
  /*
   * ★★ 这一条就是本探针存在的理由：
   *    `ticks > 秒数` ⇒ mpv 的 time-pos **比 1/秒 密** ⇒ 修复 B 有实际收益。
   *    若它是 ✗（ticks ≤ 秒数），说明 mpv 本来就只发 1 tick/秒，
   *    那修复 B **没有可见收益** —— 我会照实报，不粉饰。
   */
  ok(
    '② mpv 的 tick 频率 **> 1/秒** ⇒ 修复 B 有实际收益',
    ticks > elapsed.inSeconds,
    'ticks=$ticks  >  窗口秒数=${elapsed.inSeconds}',
  );

  final builds = [for (final t in timings) t.buildDuration.inMicroseconds];
  final rasters = [for (final t in timings) t.rasterDuration.inMicroseconds];
  final jankyBuild = builds.where((b) => b > 16700).length;
  final jankyRaster = rasters.where((b) => b > 16700).length;

  note('帧数 = ${timings.length}');
  note('build  微秒: p50=${_pct(builds, 0.50)}  p95=${_pct(builds, 0.95)}  '
      'max=${builds.isEmpty ? 0 : builds.reduce((a, b) => a > b ? a : b)}  '
      '(>16.7ms 的帧 $jankyBuild)');
  note('raster 微秒: p50=${_pct(rasters, 0.50)}  p95=${_pct(rasters, 0.95)}  '
      'max=${rasters.isEmpty ? 0 : rasters.reduce((a, b) => a > b ? a : b)}  '
      '(>16.7ms 的帧 $jankyRaster)');

  ok('③ 采到了帧耗时样本（仪器有效）', timings.isNotEmpty,
      'frames=${timings.length}');
  if (timings.isNotEmpty) {
    ok(
      '③ p95 build < 16.7ms（构建侧不卡）',
      _pct(builds, 0.95) < 16700,
      'p95=${_pct(builds, 0.95)}us',
    );
    ok(
      '③ p95 raster < 16.7ms（光栅侧不卡）',
      _pct(rasters, 0.95) < 16700,
      'p95=${_pct(rasters, 0.95)}us',
    );
  }

  // ─────────────────────────────────────────────────────────────────
  //  ④-A 真机 hover ⇒ 不该引发整页重建
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T72P]');
  debugPrint('[T72P] ── ④-A 真机 hover 60 次（改前 1:1 ⇒ 60 次重建）──');

  const hoverPos = Offset(640, 300);
  await injectMouseAdded(hoverPos);

  /*
   * ⚠️ 探针页此刻处在 `_error != null` 状态：provider id `'probe'` 不存在
   *    ⇒ `_load()` 必然抛「找不到 Provider: probe」（截图 01 里那层"播放失败"）。
   *    影响范围（已逐条核实）：
   *      · `player_page.dart:6895` 的**底栏**门控含 `_error == null` ⇒ 底栏不画；
   *      · `:6796` 的**顶部栏**只看 `_controlsVisible`，**不看** `_error`；
   *      · `:6428` 的 `MouseRegion(onHover: _showControls)` 是整棵子树的祖先，
   *        且 `RenderMouseRegion` 是 `HitTestBehavior.opaque` ⇒ 派发不受子树影响。
   *    ⇒ 本段读数对「值守卫」这个机制有效，但它**不能**代表无错误态的整页行为。
   *
   * ★★★ 为什么必须先做**阳性对照**才能报读数
   *
   * 上一轮探针在这里直接报 `dirtyCount=0`（60 次 hover 零重建）。
   * 但「修复生效 ⇒ 0 次」与「注入器/读数器根本没送到 ⇒ 也是 0 次」
   * 产生的读数**一模一样** ⇒ 没有对照时那个 0 是**空通过**。
   * （本会话铁律：永远为真的判据不是判据。）
   *
   * ⇒ 顺序改成：先在**两个极**上证明仪器有区分力，再做正式读数。
   *   对照 A（"无"极）：静置过 3 秒 ⇒ `_hideTimer` 真的把控制条藏了
   *                    ⇒ `_TopBar` 必须从树上**消失**
   *   对照 B（"有"极）：隐藏态下注入 1 次 hover
   *                    ⇒ `PlayerPage.dirty` 必须变 **true**（setState 真的发生）
   *                    ⇒ `_TopBar` 必须**回来**（hover 真的走到了 `_showControls`）
   * 两条都过，后面那个 0 才算证据；任一条不过 ⇒ 报 INSTRUMENT-FAILURE 并中止，
   * **不许**把 0 当成绩交上去。
   */
  final rootEl = root!;
  await pumpFrame();

  /*
   * ── 前置：读数器在「有」这一极先自证 ──
   *
   * ★★★ 这里**不假设**「此刻控制条可见」—— 上一版正是这么假设的，
   *     而两次实跑已经把这个假设证伪：
   *       run#2（18:31）`✓ _TopBar 已找到`
   *       run#3（18:36）`✗ ★ 找不到 _TopBar ⇒ 选择器/读数器有问题`
   *     两次的 `player_page.dart` 指纹**完全相同**（`7E0D3D0BBDF5920B`），
   *     ①②③ 的读数也逐字相同 ⇒ 差异不在产品，在**这个前置本身**。
   *
   *   机制（逐条核过源码）：`_controlsVisible` 初值确实是 `true`
   *   （`player_page.dart:487`），但它会被 `_hideTimer` 置回 false
   *   （`:5282 setState(() => _controlsVisible = false)`）。
   *   而 `_hideTimer` 只在 `_showControls()` 里装载（`:5278-5279`），
   *   `_showControls()` 的触发源之一是 `:6429 MouseRegion(onHover: ...)`
   *   —— 探针跑的是**真窗口**：它一出现，若恰好落在鼠标光标下，
   *   Windows 就会送来真实的 WM_MOUSEMOVE ⇒ 一次真 hover
   *   ⇒ 装上定时器 ⇒ **3 秒后控制条自己藏了**。
   *   而 ⓪+①+②③ 要花掉约 9 秒 ⇒ 完全够它藏完。
   *   ⇒ 「初始可见」是**时序运气**，不是不变量。
   *     把它写成断言 ⇒ 读数随机红/绿，且红的时候会错怪读数器。
   *
   *   修法：**主动建立**这个极，而不是假设它 —— 注入一次 hover
   *   （这正是生产里让控制条出现的方式），再确认读数器看得见。
   *   区分力没有丢：读数器若真坏了，这次 hover 之后**同样**看不见。
   *   而「无」极由紧随其后的对照 A（静置 3.5s 后必须消失）建立。
   */
  await injectHover(hoverPos);
  await pumpFrame();
  final topBarInitially = findTopBar(rootEl) != null;
  ok(
    '④-A[前置] hover 后控制条可见 ⇒ _TopBar 在树上（读数器"有"极有效）',
    topBarInitially,
    topBarInitially
        ? '_TopBar 已找到（已用 1 次 hover 主动建立，不靠时序运气）'
        : '★ hover 之后仍找不到 _TopBar ⇒ 选择器/读数器真的有问题',
  );
  if (!topBarInitially) {
    say('★ 结构读数器无区分力 ⇒ ④-A 不产出结论（不许把 0 当成绩）');
    await finish(1);
  }

  /*
   * ★ 先把播放位置拉回 0，给后面留够时间
   *
   * 素材只有 20s（`hevc_sample.mp4`），而 ⓪+①+②③ 已经吃掉约 9s。
   * 若播到 EOF，media_kit 会把 `playing` 置回 false ⇒ `_hideTimer` 回调里
   * `:5281 if (mounted && _playing && !_hintsOpen)` 的 `_playing` 不成立
   * ⇒ 控制条**不会**自动隐藏 ⇒ 对照 A 假失败（错怪仪器，白跑一次构建）。
   */
  final seeked = debugPlayerSeekForProbe(Duration.zero);
  note('④-A 前 seek 回 0 以留出时间：$seeked');
  await Future<void>.delayed(const Duration(milliseconds: 300));

  /*
   * ★★ 先手动把 `_hideTimer` **装上**，否则对照 A 会假失败
   *
   * `_hideTimer` 只在 `_showControls()` 内部装载（`player_page.dart:5278-5279`），
   * 而探针走的是 `_load()` 的**失败**路径（provider `'probe'` 不存在）⇒
   * `_startPlayback` 成功路径尾部的 `:2416 _showControls()` **从没执行过**
   * ⇒ 此刻 `_hideTimer == null`，静置再久也不会隐藏。
   *
   * 用 1 次真 hover 把它装上 —— 这也正是生产里发生的事
   * （鼠标一动 ⇒ `:6429 onHover` ⇒ `_showControls()`）。
   * 注意：这次 hover 时 `_controlsVisible` 还是初值 `true`（`:487`），
   * 所以它**不该**产生 setState；它唯一的作用是装载定时器。
   */
  await injectHover(hoverPos);
  final armedVisible = findTopBar(rootEl) != null;
  note('第 1 次 hover（装载 _hideTimer）后控制条仍可见 = $armedVisible');
  await pumpFrame();

  /*
   * ★★ 为什么必须把定时器的**前置条件**也打出来
   *
   * `_hideTimer` 的回调是（`player_page.dart:5279-5284`）：
   * ```dart
   * _hideTimer = Timer(const Duration(seconds: 3), () {
   *   if (mounted && _playing && !_hintsOpen) {   // ← 三个门控
   *     setState(() => _controlsVisible = false);
   *   }
   * });
   * ```
   * ⇒ 「静置 3.5 秒后控制条还在」有**两个完全不同的原因**：
   *     · `_playing == false`（或 `_hintsOpen == true`）⇒ 定时器**合法地**
   *       什么都不做 ⇒ 是**我的前置条件不满足**，不是产品问题；
   *     · 三个门控都成立却仍没隐藏 ⇒ 才是「注入器没送到」或「定时器没跑」。
   *   两者在「`_TopBar` 还在树上」这个读数上**一模一样**。
   *   上一版探针只打后者，于是那次失败**无法归因** —— 这正是本条的教训。
   */
  final playingBefore = debugPlayerIsPlaying();
  final sheetBefore = debugPlayerAnySheetOpen();
  note('对照A 前置条件：_playing=$playingBefore  _anySheetOpen=$sheetBefore  '
      '（定时器回调要求 _playing==true 且 !_hintsOpen）');

  // ── 对照 A（"无"极）：静置 3.5s，让刚装上的 _hideTimer 走完那 3 秒 ──
  say('静置 3.5s（不注入任何事件），等 _hideTimer 把控制条藏起来…');
  await Future<void>.delayed(const Duration(milliseconds: 3500));
  await pumpFrame();
  var hidItself = findTopBar(rootEl) == null;
  final playingAfter = debugPlayerIsPlaying();
  note('静置后：_TopBar 消失=$hidItself  _playing=$playingAfter');

  if (!hidItself && (playingAfter != true || sheetBefore == true)) {
    /*
     * 前置条件不成立 ⇒ 定时器**本来就该**不隐藏。
     * 这是**仪器前置**问题，不是产品结论 ⇒ 重试一次（重新装载定时器）。
     */
    note('★ 归因：定时器门控未满足（_playing=$playingAfter '
        'sheet=$sheetBefore）⇒ 上一次静置**不构成对照**，重试一次');
    await injectHover(hoverPos);
    await Future<void>.delayed(const Duration(milliseconds: 4200));
    await pumpFrame();
    hidItself = findTopBar(rootEl) == null;
    note('重试（重新装载 + 静置 4.2s）后 _TopBar 消失=$hidItself  '
        '_playing=${debugPlayerIsPlaying()}');
  }

  var instrumentOk = true;
  if (hidItself) {
    ok(
      '④-A[对照A] 静置过 3 秒 ⇒ 控制条自动隐藏（_TopBar 从树上消失）',
      true,
      '_TopBar 已消失',
    );
  } else {
    /*
     * ★ 这里**不** `exit`，而是记一条 `skip`
     *
     * 历史事故：上一版在这里 `finish(1)` 直接退出，把后面**独立的** ④-C
     * （抽屉关着不该取频道列表）一起丢掉了 —— 一次仪器失败连累了另一段
     * 本可产出的证据。所以：本段降级为「未评估」，**继续往下跑**。
     */
    skip('④-A[对照A] 控制条未自动隐藏（_playing=${debugPlayerIsPlaying()} '
        'sheet=${debugPlayerAnySheetOpen()}）⇒ 无法建立"无"极');
    instrumentOk = false;
  }

  // ── 对照 B（"有"极）：1 次 hover ⇒ 必须真的 setState + 控制条回来 ──
  //
  // 这一步是整段的**要害**：`_controlsVisible` 现在是 false，
  // 所以这次 hover 必须命中 `:5275 if (mounted && !_controlsVisible)`
  // ⇒ `setState` ⇒ `pageEl.dirty == true`。
  // 若这里读到 false，说明「注入器没送到」或「dirty 读数器是死的」——
  // 那前面那个 0 就**一文不值**，必须报 INSTRUMENT-FAILURE。
  var dirtyAfterCtrl = false;
  var cameBack = false;
  if (instrumentOk) {
    final (cleanBefore, dac, attempt) =
        await hoverOnceClean(pageEl, hoverPos);
    dirtyAfterCtrl = dac;
    ok(
      '④-A[对照B] 隐藏态下 1 次 hover ⇒ PlayerPage 被标脏（注入器+读数器都活着）',
      cleanBefore && dirtyAfterCtrl,
      '前置干净=$cleanBefore  注入后 dirty=$dirtyAfterCtrl  第 $attempt 次尝试',
    );
    await pumpFrame();
    cameBack = findTopBar(rootEl) != null;
    ok(
      '④-A[对照B] 同一次 hover ⇒ 控制条真的回来了（_showControls 确实被调到）',
      cameBack,
      cameBack ? '_TopBar 回来了' : '★ 没回来',
    );
    if (!dirtyAfterCtrl || !cameBack) {
      skip('④-A[对照B] 阳性对照失败（dirty=$dirtyAfterCtrl 回显=$cameBack）'
          '⇒ 0 次将无法解释');
      instrumentOk = false;
    }
  } else {
    skip('④-A[对照B] 未执行（对照A 已失败 ⇒ 无法构造隐藏态）');
  }

  // ── 正式读数：控制条已可见时，60 次 hover 不该引发任何重建 ──
  if (instrumentOk) {
    note('★ 仪器已在两极验证：有极=$topBarInitially 无极=$hidItself '
        '标脏=$dirtyAfterCtrl 回显=$cameBack');

    /*
     * ★★ 帧耗时**必须**在负载下量（这是本段新增的仪器）
     *
     * ②③ 那个 5 秒窗口里页面是**静止**的（只有 1 次/秒的 setState）
     * ⇒ 实测只采到 **4 帧**。用 4 帧去说「p95 < 16.7ms ⇒ 不卡」
     *   是**在空载下证明不卡** —— 而用户说的"卡"发生在**鼠标动的时候**。
     * ⇒ 把计时器挂在 hover 风暴**期间**：这一段的每轮都强制一帧，
     *   量的才是"鼠标在播放页上移动"这个真实场景的帧耗时。
     */
    final hoverTimings = <FrameTiming>[];
    void onHoverTimings(List<FrameTiming> t) => hoverTimings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(onHoverTimings);

    var dirtyCount = 0;
    final dirtyIdx = <int>[];
    const hoverCount = 60;
    for (var i = 0; i < hoverCount; i++) {
      await pumpFrame(); // 清掉上一帧的 dirty
      final wasDirty = pageEl.dirty;
      if (wasDirty) {
        // 前置条件被破坏（别的东西先把它标脏了）⇒ 本次样本作废，不猜
        note('  样本 $i 前置条件失败（注入前已 dirty）⇒ 跳过');
        continue;
      }
      await injectHover(hoverPos);
      if (pageEl.dirty) {
        dirtyCount++;
        dirtyIdx.add(i);
      }
    }

    /*
     * ★★★ 摘回调**之前**必须先等引擎把耗时送回来 —— 这是第一次跑
     *     `③[负载] frames=0` 的真因，不是"引擎不支持"。
     *
     * 机制（都在框架源码里核过）：
     *   · `FrameTiming` 是**光栅化完成之后**才上报的（`platform_dispatcher.dart:602-622`
     *     明确说它是"recently rasterized frames"的耗时）；
     *   · 而 `pumpFrame()` 只等 UI 线程的 `endOfFrame`（build/layout/paint 结束），
     *     **不等光栅线程**（`scheduler/binding.dart` 的 `endOfFrame` 语义）；
     *   · 风暴循环是背靠背强制帧，UI 线程远快于光栅线程（②③ 实测
     *     raster p50≈2.1ms/帧 ⇒ 60 帧要 ≈130ms 才光栅完）；
     *   · 而 `removeTimingsCallback` 在列表清空时会把
     *     `platformDispatcher.onReportTimings = null`
     *     （`scheduler/binding.dart:334-336`）⇒ 引擎**停止收集**，
     *     尚未送达的批次**直接丢掉**。
     *   ⇒ 循环跑完立刻摘回调 = 把还没送到的样本自己扔掉，读数必然是 0。
     *
     * 修法：保持注册，一边继续强制帧（仍是"播放中 + 鼠标在动"的同一负载）
     *       一边轮询，直到攒够样本或超时。**不放宽判据**（仍要 ≥20 条）。
     */
    var settleMs = 0;
    var extraFrames = 0;
    while (hoverTimings.length < 20 && settleMs < 4000) {
      await pumpFrame();
      await injectHover(hoverPos);
      extraFrames++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      settleMs += 20;
    }
    note('风暴后补帧 $extraFrames 次 / 等 ${settleMs}ms ⇒ 样本 ${hoverTimings.length} 条');

    SchedulerBinding.instance.removeTimingsCallback(onHoverTimings);
    await pumpFrame();
    final stillVisible = findTopBar(rootEl) != null;
    note('注入 hover $hoverCount 次 ⇒ 引发重建 $dirtyCount 次  '
        '下标=${dirtyIdx.isEmpty ? "无" : dirtyIdx.join(",")}');
    note('循环结束时控制条仍可见 = $stillVisible  '
        '（可见 ⇒ 每次 hover 都命中值守卫 ⇒ 0 次正是预期值）');

    final hb = [for (final t in hoverTimings) t.buildDuration.inMicroseconds];
    final hr = [for (final t in hoverTimings) t.rasterDuration.inMicroseconds];
    final hJankBuild = hb.where((b) => b > 16700).length;
    final hJankRaster = hr.where((b) => b > 16700).length;
    note('hover 风暴期间帧数 = ${hoverTimings.length}');
    note('  build  微秒: p50=${_pct(hb, 0.50)}  p95=${_pct(hb, 0.95)}  '
        'max=${hb.isEmpty ? 0 : hb.reduce((a, b) => a > b ? a : b)}  '
        '(>16.7ms 的帧 $hJankBuild)');
    note('  raster 微秒: p50=${_pct(hr, 0.50)}  p95=${_pct(hr, 0.95)}  '
        'max=${hr.isEmpty ? 0 : hr.reduce((a, b) => a > b ? a : b)}  '
        '(>16.7ms 的帧 $hJankRaster)');

    ok('③[负载] hover 风暴期间采到帧样本（仪器有效）',
        hoverTimings.length >= 20, 'frames=${hoverTimings.length}');
    if (hoverTimings.length >= 20) {
      ok(
        '③[负载] hover 风暴期间 p95 build < 16.7ms',
        _pct(hb, 0.95) < 16700,
        'p95=${_pct(hb, 0.95)}us  max=${hb.isEmpty ? 0 : hb.reduce((a, b) => a > b ? a : b)}us',
      );
      ok(
        '③[负载] hover 风暴期间 p95 raster < 16.7ms',
        _pct(hr, 0.95) < 16700,
        'p95=${_pct(hr, 0.95)}us  max=${hr.isEmpty ? 0 : hr.reduce((a, b) => a > b ? a : b)}us',
      );
    } else {
      skip('③[负载] 帧样本不足（${hoverTimings.length} < 20）⇒ 不产出结论');
    }

    /*
     * ★ 判据定成 `<= 1` 而不是 `== 0`，理由（不是放宽标准，是**说清语义**）：
     *   鼠标停着 3 秒后控制条会自动隐藏（`_hideTimer`，`player_page.dart:5279`）
     *   ⇒ 那一瞬间的第一次 hover **本来就该**把它重新显示出来（这是设计），
     *     那次 setState 是**正确的**。
     *   而修复前的 bug 是「**每一次** hover 都 setState」⇒ 60 次。
     *   ⇒ 真正的判据是「不是 1:1」，`<= 1` 精确表达了这一点。
     */
    ok(
      '④-A 60 次 hover ⇒ 重建 ≤ 1 次（改前 1:1 ⇒ 60 次）',
      dirtyCount <= 1,
      'dirtyCount=$dirtyCount',
    );
    ok(
      '④-A 除"重新显示控制条"外无一次多余重建',
      dirtyIdx.length <= 1,
      '下标=$dirtyIdx',
    );
  } else {
    skip('④-A 正式读数未执行（仪器未在两极自证）');
  }

  // ─────────────────────────────────────────────────────────────────
  //  ④-C 抽屉关着 ⇒ 不该去取频道列表
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T72P]');
  debugPrint('[T72P] ── ④-C 抽屉关着时取列表 / 开着时取 ──');

  var pushedSec = 0;
  Future<void> pushTickAndFrame() async {
    debugPlayerPushPositionForProbe(Duration(seconds: pushedSec++));
    await pumpFrame();
  }

  liveChannelsCalls = 0;
  const closedRebuilds = 10;
  for (var i = 0; i < closedRebuilds; i++) {
    await pushTickAndFrame();
  }
  final closedCalls = liveChannelsCalls;
  ok(
    '④-C 抽屉关着：$closedRebuilds 次整页重建 ⇒ onLiveChannels 调 0 次',
    closedCalls == 0,
    'calls=$closedCalls（改前 1:1 ⇒ $closedRebuilds 次）',
  );

  final drawerOpened = debugPlayerOpenLiveChannelsForProbe();
  ok('④-C 抽屉能打开（探针钩子可用）', drawerOpened);
  await pumpFrame();

  liveChannelsCalls = 0;
  const openRebuilds = 5;
  for (var i = 0; i < openRebuilds; i++) {
    await pushTickAndFrame();
  }
  final openCalls = liveChannelsCalls;
  ok(
    '④-C 抽屉开着：$openRebuilds 次重建 ⇒ onLiveChannels 被调（列表新鲜）',
    openCalls >= 3,
    'calls=$openCalls',
  );

  final (_, c2) = await shoot('02-drawer');
  ok('抽屉截图非退化（>20 色）', c2 > 20, '颜色数=$c2');

  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T72P]');
  debugPrint('[T72P] ══════ 结果: pass=$pass fail=$fail ══════');
  await finish(fail == 0 ? 0 : 1);
}
