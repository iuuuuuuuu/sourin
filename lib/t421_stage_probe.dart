/// t421 — 「同一台车、同一世代、逐段启动」的渲染二分探针
///
/// ═══════════════════════════════════════════════════════════════════
///  要回答的问题
/// ═══════════════════════════════════════════════════════════════════
///
/// 已测到的三个事实（都在同一台 TV 模拟器 `emulator-5556` 上）：
///
///   A. **x86_64 产品包** → 正常渲染（截图 155 色，真实 TV 界面）
///   B. **arm64 widgets-only hello**（`lib/t419_hello_arm64.dart`）→ 正常
///      渲染（截图 81 色，`px(0,0)=#1E63C8` = 我们指定的蓝）
///   C. **arm64 产品包** → `screencap` **纯黑**（5 张全是 `uniqueColours=1`）
///
/// A ⇒ 产品代码本身没问题；B ⇒ 翻译层跑得动 Flutter arm64。
/// 但 **C 依然纯黑**，而 logcat 里 `[SHELL] FIRST_FRAME_RENDERED` 打了、
/// `ActivityTaskManager: Fully drawn … +3s224ms` 也报了。
///
/// ⇒ 「Dart 侧认为画完了」与「合成器真的拿到 buffer」是**两个不同的量**。
///
/// ═══════════════════════════════════════════════════════════════════
///  本探针的做法：把「哪一段启动代码让画面变黑」变成可读读数
/// ═══════════════════════════════════════════════════════════════════
///
/// **严格照抄 `lib/shell.dart` 的 `main()` 顺序**，但在**每两步之间**
/// 插入一次「金丝雀渲染」：`runApp` 一棵只有纯色块 + 一行大字的树，
/// 停 8 秒，让**进程外**的 `adb exec-out screencap` 能拍到。
///
/// 每一段用**不同的颜色**，而且颜色和文字**都**写进画面 ——
/// 于是「哪一段之后变黑」既可以用像素读，也可以用肉眼读（两个独立读数）。
///
/// 关键设计：**一次构建、一次运行、逐段截图**。
/// 不是「每段重编一个 APK」——那样每跑一次都要 168 秒，而且车况会漂。
///
/// ═══════════════════════════════════════════════════════════════════
///  ★ 双仪器：进程内 `toImage()` vs 进程外 `screencap`
/// ═══════════════════════════════════════════════════════════════════
///
/// 每段除了外部截图，还做一次**进程内** `RenderRepaintBoundary.toImage()`
/// 读回像素。两个读数的组合是有判别力的：
///
/// ```text
/// 进程内     进程外     结论
/// ---------  ---------  ------------------------------------------
/// 有色       有色       这一段没问题
/// 有色       黑         ★ Skia 画出来了，但**没能送上屏幕**
///                       ⇒ 断点在 surface / swapchain / 合成器交接
/// 黑         黑         ★ Skia 自己就没画出来
///                       ⇒ 断点在光栅化（shader / GLES 调用）
/// ```
///
/// 没有这个双读数，「黑」只能说明「屏幕是黑的」，不能说明断在哪。
///
/// ═══════════════════════════════════════════════════════════════════
///  跑法
/// ═══════════════════════════════════════════════════════════════════
///
/// ```text
/// flutter build apk --release --target-platform android-arm64 \
///     -t lib/t421_stage_probe.dart
/// adb -s emulator-5556 install -r --abi arm64-v8a <apk>
/// adb -s emulator-5556 shell am start -n app.sourin.sourin_spike/.MainActivity
/// ```
///
/// 探针把当前段号写进 `<外部目录>/t421_stage.txt`，驱动脚本轮询这个文件、
/// 段号一变就 `screencap` 一张 —— 这样截图**落在进程外**，不受被测进程影响。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';

const String kTag = '[T421]';

/// 每段停多久，留给进程外截图。
const Duration kHold = Duration(seconds: 8);

final GlobalKey _rootKey = GlobalKey();

String _workDir = '';

/// 每段的颜色 —— **必须彼此差得远**，这样一个像素就能分辨是哪一段。
///
/// 顺序与 `lib/shell.dart` 的 `main()` 一一对应：
/// ```text
/// 0  基线（引擎刚起来，什么都没做）
/// 1  MediaKit.ensureInitialized()      shell.dart:276
/// 2  Device.init()                     shell.dart:445 附近
/// 3  _resolveDataDir() + UiPrefs.load  shell.dart:484-494
/// 4  SourinCore.startAsync(dir)        shell.dart:514
/// 5  LiquidGlassWidgets.initialize()   shell.dart:542
/// 6  runApp(SourinApp(...))            shell.dart:546   ← 产品整棵树
/// ```
const List<int> kStageColors = <int>[
  0xFF1E63C8, // 0 蓝
  0xFFE8001E, // 1 红
  0xFF1EC863, // 2 绿
  0xFFC81EC8, // 3 洋红
  0xFFE8C81E, // 4 黄
  0xFF1EC8C8, // 5 青
  0xFF000000, // 6 产品（这个颜色只是占位，第 6 段不画金丝雀）
];

const List<String> kStageNames = <String>[
  'baseline',
  'MediaKit.ensureInitialized',
  'Device.init',
  'resolveDataDir+UiPrefs',
  'SourinCore.startAsync',
  'LiquidGlassWidgets.initialize',
  'runApp(SourinApp)',
];

void _log(String line) {
  debugPrint('$kTag $line');
}

Future<void> _append(String line) async {
  try {
    await File('$_workDir/t421_report.txt').writeAsString(
      '${DateTime.now().toIso8601String()}  $line\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// 把段号落盘 —— 这是进程外驱动脚本的**同步信号**。
Future<void> _writeStage(int stage) async {
  try {
    await File('$_workDir/t421_stage.txt').writeAsString('$stage', flush: true);
  } catch (_) {}
}

/// 让出若干帧。
///
/// ⚠️ `endOfFrame` 必须带 timeout —— 否则引擎不出帧时这里**静默挂死**，
///    而挂死看起来和「黑屏」一模一样（都只是"没有画面"）。
Future<void> _settle() async {
  for (int i = 0; i < 3; i++) {
    try {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 超时/异常都不致命：继续，读数会如实反映。
    }
  }
}

/// 进程内读回像素（仪器一）。
Future<String> _inProc() async {
  try {
    final ctx = _rootKey.currentContext;
    if (ctx == null) return 'no-context';
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return 'not-boundary:${ro.runtimeType}';
    final ui.Image img = await ro.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (bd == null) return 'no-bytes';
    final bytes = bd.buffer.asUint8List();
    final set = <int>{};
    int n = 0;
    for (int i = 0; i + 3 < bytes.length; i += 4 * 7) {
      set.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
      n++;
    }
    final top = set
        .take(4)
        .map((c) => '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}')
        .join(',');
    final corner = bytes.length >= 4
        ? '#${((bytes[0] << 16) | (bytes[1] << 8) | bytes[2]).toRadixString(16).padLeft(6, '0').toUpperCase()}'
        : 'n/a';
    return 'colors=${set.length} sampled=$n px00=$corner top=[$top]';
  } catch (e) {
    return 'ERR:$e';
  }
}

/// 画一段金丝雀、读一次进程内像素、停 `kHold` 让外面截图。
Future<void> _canary(int stage) async {
  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: _Canary(stage: stage),
    ),
  );
  await _settle();

  final read = await _inProc();
  _log('STAGE $stage (${kStageNames[stage]}) INPROC $read');
  await _append('STAGE $stage (${kStageNames[stage]}) INPROC $read');

  await _writeStage(stage);
  _log('STAGE $stage HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE $stage HOLD-END');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final d = await getExternalStorageDirectory();
    _workDir = d?.path ??
        '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
  } catch (_) {
    _workDir = '/data/local/tmp';
  }
  try {
    await Directory(_workDir).create(recursive: true);
  } catch (_) {}

  await _append('================ t421 start ================');
  _log('workdir=$_workDir');

  // ── 段 0：基线 ────────────────────────────────────────────────
  await _canary(0);

  // ── 段 1：MediaKit.ensureInitialized()   [shell.dart:276] ─────
  String mkNote = 'ok';
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    mkNote = 'ERR:$e';
  }
  _log('CALL MediaKit.ensureInitialized -> $mkNote');
  await _append('CALL MediaKit.ensureInitialized -> $mkNote');
  await _canary(1);

  // ── 段 2：Device.init()                  [shell.dart:445 附近] ─
  String devNote = 'ok';
  try {
    await Device.init();
  } catch (e) {
    devNote = 'ERR:$e';
  }
  _log('CALL Device.init -> $devNote kind=${Device.kind} '
      'isTv=${Device.isTv} isTouchOnly=${Device.isTouchOnly}');
  await _append('CALL Device.init -> $devNote kind=${Device.kind} '
      'isTv=${Device.isTv} isTouchOnly=${Device.isTouchOnly}');
  await _canary(2);

  // ── 段 3：_resolveDataDir() + UiPrefs.load()  [shell.dart:484-494]
  String dirNote = 'ok';
  String dir = _workDir;
  try {
    dir = await _resolveDataDir();
    await UiPrefs.load(dir);
  } catch (e) {
    dirNote = 'ERR:$e';
  }
  _log('CALL resolveDataDir+UiPrefs.load -> $dirNote dir=$dir');
  await _append('CALL resolveDataDir+UiPrefs.load -> $dirNote dir=$dir');
  await _canary(3);

  // ── 段 4：SourinCore.startAsync(dir)      [shell.dart:514] ────
  String coreNote = 'ok';
  try {
    final r = await SourinCore.startAsync(dir);
    _log('CALL SourinCore.startAsync -> $r');
    await _append('CALL SourinCore.startAsync -> $r');
  } catch (e) {
    coreNote = 'ERR:$e';
  }
  _log('CALL SourinCore.startAsync note=$coreNote');
  await _append('CALL SourinCore.startAsync note=$coreNote');
  await _canary(4);

  // ── 段 5：LiquidGlassWidgets.initialize() [shell.dart:542] ────
  String lgNote = 'ok';
  try {
    await LiquidGlassWidgets.initialize();
  } catch (e) {
    lgNote = 'ERR:$e';
  }
  _log('CALL LiquidGlassWidgets.initialize -> $lgNote');
  await _append('CALL LiquidGlassWidgets.initialize -> $lgNote');
  await _canary(5);

  // ── 段 6：产品整棵树                     [shell.dart:546] ─────
  runApp(SourinApp(coreError: null, coreDataDir: dir));
  _log('CALL runApp(SourinApp) done');
  await _append('CALL runApp(SourinApp) done');
  await _settle();
  await Future<void>.delayed(const Duration(seconds: 6));
  await _writeStage(6);
  _log('STAGE 6 (${kStageNames[6]}) HOLD-BEGIN');
  await Future<void>.delayed(kHold);
  _log('STAGE 6 HOLD-END');

  _log('DONE');
  await _append('================ t421 done ================');
  exit(0);
}

/// 金丝雀：纯色底 + 一行大字。颜色和文字**都**编码了段号 ⇒ 两个独立读数。
class _Canary extends StatelessWidget {
  const _Canary({required this.stage});

  final int stage;

  @override
  Widget build(BuildContext context) {
    final int c = kStageColors[stage];
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(c),
        child: SizedBox.expand(
          child: Center(
            child: Text(
              'S$stage ${kStageNames[stage]}',
              textAlign: TextAlign.center,
              softWrap: true,
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFFFFFF),
                shadows: <Shadow>[
                  Shadow(offset: Offset(3, 3), blurRadius: 6, color: Color(0xFF000000)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 产品数据目录。Android 上 `getApplicationSupportDirectory()` 就是
/// `/data/user/0/<pkg>/files` —— 与产品自己用的私有目录同址
/// （实测该目录里有 `ui-prefs.json`，正是 `UiPrefs` 写的那个）。
Future<String> _resolveDataDir() async {
  final d = await getApplicationSupportDirectory();
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}
