/*
 * t285 -- 绕开 EGL 拿真画面的独立入口点探针
 *
 * 背景：Android 模拟器上产品黑屏。t113 反汇编推断 eglCreateContext 因实现
 * 未提供 EGL_KHR_create_context 而被拒（mpv 无条件写入属性名 0x30FC =
 * EGL_CONTEXT_FLAGS_KHR）。t282 已证明：把同一张属性表喂给一个确实广告了
 * 该扩展的实现（Windows 上 Flutter 自带 ANGLE），eglCreateContext 直接成功。
 *
 * 本探针走 `vo=mediacodec_embed`：MediaCodec 直接输出到 Surface，
 * **完全不建 EGL context**，用来回答一个问题：
 *     「绕开 EGL 之后，链路能不能出图？」
 *
 * 这不回答「产品该不该改 VO」，也不改任何生产代码。
 * 本文件是独立入口点：`flutter build apk --release --split-per-abi -t lib/t285_mediacodec_embed_probe.dart`
 *
 * 输出：
 *   1) logcat，前缀 `[T285]`，**纯 ASCII**（宿主控制台代码页会咬非 ASCII）
 *   2) <外部 files 目录>/t285_report.txt（UTF-8，完整报告）
 *   3) <外部 files 目录>/t285_phase.txt（阶段标记，供驱动轮询的兜底通路）
 *
 * 配置（驱动用 adb push 写，探针启动时读；缺省则用内置默认值）：
 *   <外部 files 目录>/t285_config.txt
 *     arm=A|B|C|D
 *     media=<绝对路径>
 *     hold_seconds=45
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

const String kTag = '[T285]';

// ─────────────────────────────────────────────────────────────
// 臂定义
//
// 三个 VO 方案按序试（lead 指定），外加一个阴性对照：
//   A  mediacodec_embed + hwdec=mediacodec   —— MediaCodec 直出 Surface
//   B  mediacodec_embed + hwdec=no           —— 同上但软解（排除硬解器缺失）
//   C  gpu + hwdec=no + opengl-es=no         —— 属性表退化成 {0x3098,2,0x3038}
//   D  gpu + hwdec=no（opengl-es 保持 yes）   —— **阴性对照**：产品默认路径
//
// ★ C 的依据：t113 §3.1 反汇编 `attrs[2] = opengl-es ? 0x30FC : 0x3038`；
//   而 t83_egl_matrix 的 A2 = `{0x3098,2,0x3038}` 是 emulation **接受**的那张表。
// ★ D 是阴性对照，不是「第四个方案」——它必须仍然是黑屏，
//   否则「两个 VO 读数相反」这个归因就不成立。
// ─────────────────────────────────────────────────────────────
class Arm {
  const Arm(this.id, this.vo, this.hwdec, this.openglEsOff, this.note);
  final String id;
  final String vo;
  final String hwdec;
  final bool openglEsOff;
  final String note;
}

const List<Arm> kArms = <Arm>[
  Arm('A', 'mediacodec_embed', 'mediacodec', false,
      'MediaCodec direct-to-Surface, no EGL context at all'),
  Arm('B', 'mediacodec_embed', 'no', false,
      'same as A but software decode (rules out missing hw decoder)'),
  Arm('C', 'gpu', 'no', true,
      'default VO with opengl-es=no => attrs {0x3098,2,0x3038} (matrix A2)'),
  Arm('D', 'gpu', 'no', false,
      'NEGATIVE CONTROL: product default path (opengl-es=yes)'),
];

// ─────────────────────────────────────────────────────────────
// 要读的 mpv 属性 —— 按「链路阶段」组织，便于把黑屏钉在某一步
// ─────────────────────────────────────────────────────────────
const List<String> kProps = <String>[
  // S1 demux
  'track-list/count', 'duration', 'demuxer', 'file-format',
  // S2 视频轨
  'video-codec', 'video-format', 'width', 'height', 'video-params/colormatrix',
  'video-params/pixelformat', 'video-params/w', 'video-params/h',
  // S3 解码器
  'hwdec', 'hwdec-current', 'video-dec-params/hw-pixelformat',
  'decoder-frame-drop-count', 'estimated-vf-fps', 'display-fps',
  // S4 播放推进
  'time-pos', 'eof-reached', 'core-idle', 'paused-for-cache',
  'cache-buffering-state', 'pause',
  // S5 surface / VO
  'vo', 'current-vo', 'vid', 'wid', 'android-surface-size',
  'gpu-context', 'opengl-es', 'force-window',
  // 字幕（产品配置的忠实复刻，用于确认我们没把探针配歪）
  'sub-fonts-dir', 'sub-font', 'sub-font-provider', 'sid', 'sub-visibility',
];

// ─────────────────────────────────────────────────────────────
// 运行期状态
// ─────────────────────────────────────────────────────────────
final StringBuffer _rep = StringBuffer();
final List<String> _mpvlog = <String>[];
final List<String> _logcat = <String>[];

String _workDir = '';
String _mediaPath = '';
Arm _arm = kArms[0];
int _holdSeconds = 45;

/// 阶段时间戳的零点（main() 一开始就设）。用相对毫秒而不是墙钟，是为了让
/// 「哪一段花了多久」直接可读，也避免设备时钟与宿主时钟不一致带来的误读。
DateTime _t0 = DateTime.now();

/// 一条消息走三条路：内存报告、logcat（ASCII 前缀）、阶段文件（兜底）。
void _emit(String line) {
  _rep.writeln(line);
  // logcat 只走 ASCII —— 宿主控制台/管道上的非 ASCII 有被咬的历史
  final ascii = line.replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  _logcat.add(ascii);
  debugPrint('$kTag $ascii');
}

void _phase(String name, [String extra = '']) {
  // 相对 main() 起点的毫秒数：阶段之间的间隔本身就是读数（哪一段卡住）
  final ms = DateTime.now().difference(_t0).inMilliseconds;
  final line = 'PHASE $name t=$ms${extra.isEmpty ? '' : ' $extra'}';
  _emit(line);
  try {
    // ★ 追加而非覆盖：驱动只需「文件里出现过 PHASE ready」，而保留全序列
    //   能在探针中途死掉时告诉我们死在哪一段（覆盖式只剩最后一行）。
    File('$_workDir/t285_phase.txt')
        .writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 阶段文件只是兜底通路，写不了不影响主判据（logcat 才是主通路）
  }
}

void _section(String title) {
  _emit('');
  _emit('===== $title =====');
}

Future<String> _prop(NativePlayer n, String key) async {
  try {
    final v = await n.getProperty(key).timeout(const Duration(seconds: 8));
    return v;
  } catch (e) {
    return '<read-failed: $e>';
  }
}

Future<Map<String, String>> _snapshot(NativePlayer n, String label) async {
  _section('PROPS @ $label');
  final out = <String, String>{};
  for (final k in kProps) {
    final v = await _prop(n, k);
    out[k] = v;
    _emit('  $k = $v');
  }
  return out;
}

/// 等 `pred` 为真，最多 `timeout`；返回实际耗时或 null。
Future<Duration?> _waitFor(Future<bool> Function() pred, Duration timeout,
    {Duration step = const Duration(milliseconds: 250)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    try {
      if (await pred()) return sw.elapsed;
    } catch (_) {
      // 轮询期间读属性失败不算致命，继续等
    }
    await Future<void>.delayed(step);
  }
  return null;
}

// ─────────────────────────────────────────────────────────────
// 舞台：真渲染 Video widget 的最小形态
//
// ★ 必须推真 `Video` widget —— media_kit 的 controller 初始化依赖
//   `VideoOutput.Resize` 回调，而该回调只在 native 真的建出 surface 后才来。
//   不推 widget ⇒ `wid` 恒为 0 ⇒ `vo` 恒为 'null' ⇒ 永远黑屏（与产品症状同形）。
//
// ★ 左上角 40x40 的循环变色方块 = **仪器活性指示器**：
//   它证明 screencap 抓得到本 App 的、随时间变化的像素。
//   驱动侧测量时会把这个角（物理 300x300）mask 掉，不污染视频区域的读数。
// ─────────────────────────────────────────────────────────────
class _Stage extends StatefulWidget {
  const _Stage({required this.player, required this.controller});
  final Player player;
  final VideoController controller;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 全屏视频：避免任何「卡片定位」的脆弱性
              Video(
                controller: widget.controller,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
              const Positioned(
                left: 0,
                top: 0,
                child: _LivenessSquare(),
              ),
            ],
          ),
        ),
      );
}

/// 变色方块单独抽出来，免得整棵舞台树因它重建。
class _LivenessSquare extends StatefulWidget {
  const _LivenessSquare();
  @override
  State<_LivenessSquare> createState() => _LivenessSquareState();
}

class _LivenessSquareState extends State<_LivenessSquare> {
  static const List<Color> _palette = <Color>[
    Color(0xFFFF0000),
    Color(0xFF00FF00),
    Color(0xFF0000FF),
    Color(0xFFFFFF00),
  ];
  int _i = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() => _i = (_i + 1) % _palette.length);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 40,
        height: 40,
        child: ColoredBox(color: _palette[_i]),
      );
}

// ─────────────────────────────────────────────────────────────
// 配置读取
// ─────────────────────────────────────────────────────────────
Future<String> _resolveWorkDir() async {
  try {
    final d = await getExternalStorageDirectory();
    if (d != null) return d.path;
  } catch (e) {
    debugPrint('$kTag getExternalStorageDirectory failed: $e');
  }
  // 兜底：Android 上 app 自己的外部 files 目录形状固定
  return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
}

void _readConfig() {
  final f = File('$_workDir/t285_config.txt');
  if (!f.existsSync()) {
    _emit('CONFIG file absent ($_workDir/t285_config.txt) -> built-in defaults');
    return;
  }
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final k = line.substring(0, eq).trim();
    final v = line.substring(eq + 1).trim();
    switch (k) {
      case 'arm':
        final m = kArms.where((a) => a.id == v.toUpperCase());
        if (m.isNotEmpty) _arm = m.first;
        break;
      case 'media':
        _mediaPath = v;
        break;
      case 'hold_seconds':
        _holdSeconds = int.tryParse(v) ?? _holdSeconds;
        break;
    }
  }
  _emit('CONFIG loaded from ${f.path}');
}

// ─────────────────────────────────────────────────────────────
// 主流程
// ─────────────────────────────────────────────────────────────
Future<void> main() async {
  // 同步打印，避免 debugPrintThrottled 把行丢掉（报告完整性 > 流畅度）
  debugPrint = debugPrintSynchronously;

  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  _workDir = await _resolveWorkDir();
  // ★ 先清掉上一臂的阶段文件：驱动靠「文件里出现 PHASE ready」决定何时截图，
  //   若上一臂的 ready 还在，驱动会对着还没起播的屏幕截图 ⇒ 假读数。
  try {
    File('$_workDir/t285_phase.txt').writeAsStringSync('', flush: true);
    File('$_workDir/t285_report.txt').writeAsStringSync('', flush: true);
  } catch (_) {}
  _t0 = DateTime.now();
  _readConfig();
  if (_mediaPath.isEmpty) {
    _mediaPath = '$_workDir/media/ctl_test.mp4';
  }

  _emit('T285 mediacodec_embed probe');
  _emit('generated = ${DateTime.now().toIso8601String()}');
  _emit('workdir = $_workDir');
  _emit('media = $_mediaPath (exists=${File(_mediaPath).existsSync()})');
  _emit('arm = ${_arm.id}  vo=${_arm.vo}  hwdec=${_arm.hwdec}  '
      'openglEsOff=${_arm.openglEsOff}');
  _emit('arm note = ${_arm.note}');
  _emit('hold_seconds = $_holdSeconds');

  if (!File(_mediaPath).existsSync()) {
    _emit('REFUSING: media missing -- instrument cannot produce a reading');
    _phase('refusing_media_missing');
    _finish(2);
    return;
  }

  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    _emit('REFUSING: MediaKit.ensureInitialized failed: $e');
    _phase('refusing_mediakit');
    _finish(2);
    return;
  }

  _phase('arm_start', 'arm=${_arm.id}');

  final player = Player(
    configuration: const PlayerConfiguration(
      libass: true,
      logLevel: MPVLogLevel.v, // ★ 默认 error 会把 'Loading font file' 之类全丢掉
    ),
  );

  // mpv 日志：全量进内存，过滤后的进 logcat
  final logSub = player.stream.log.listen((PlayerLog e) {
    if (_mpvlog.length < 6000) {
      _mpvlog.add('[${e.prefix}] ${e.text}');
    }
  });

  final controller = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      vo: _arm.vo,
      hwdec: _arm.hwdec, // ★ 显式传 ⇒ 绕过 media_kit 的模拟器软解门
    ),
  );

  runApp(_Stage(player: player, controller: controller));

  // ── 等 controller 就绪 ──
  // VideoController 内部先 addPostFrameCallback 再 create()；
  // notifier 变非空时 create() 已经跑完（含它自己那批 setProperties）。
  final ctlOk = await _waitFor(
    () async => controller.notifier.value != null,
    const Duration(seconds: 40),
  );
  if (ctlOk == null) {
    _emit('REFUSING: VideoController never became ready (40s)');
    _phase('refusing_controller');
    await _dumpLogs(player);
    _finish(2);
    return;
  }
  _phase('controller_ready', 'after=${ctlOk.inMilliseconds}ms');

  final native = player.platform;
  if (native is! NativePlayer) {
    _emit('REFUSING: platform is not NativePlayer (${native.runtimeType})');
    _phase('refusing_not_native');
    _finish(2);
    return;
  }

  // ── 臂专属的 create() 之后覆盖 ──
  // media_kit 的 create() 无条件写 opengl-es=yes；想关掉只能事后覆盖。
  // 此时 wid 还是 0 ⇒ vo 还是 'null' ⇒ VO 尚未建立 ⇒ 覆盖能生效。
  if (_arm.openglEsOff) {
    try {
      await native.setProperty('opengl-es', 'no');
      _emit('override: opengl-es=no applied (post-create)');
    } catch (e) {
      _emit('override FAILED: opengl-es=no -> $e');
    }
  }

  await _snapshot(native, 'after_controller_create');

  // ── 起播 ──
  try {
    await player.open(Media(_mediaPath), play: true);
    _emit('open() returned OK');
  } catch (e) {
    _emit('open() THREW: $e');
  }
  _phase('opened');

  // ── 等视频参数（这是 wid 的鸡生蛋起点）──
  final vpOk = await _waitFor(
    () async {
      final w = await native.getProperty('width').timeout(const Duration(seconds: 5));
      final h = await native.getProperty('height').timeout(const Duration(seconds: 5));
      final wi = int.tryParse(w.trim()) ?? 0;
      final hi = int.tryParse(h.trim()) ?? 0;
      return wi > 0 && hi > 0;
    },
    const Duration(seconds: 40),
  );
  if (vpOk == null) {
    _emit('WARN: video params never became non-zero within 40s');
    _phase('no_video_params');
  } else {
    _emit('video params arrived after ${vpOk.inMilliseconds}ms');
    _phase('video_params', 'after=${vpOk.inMilliseconds}ms');
  }

  // ── 稳定期：等 wid -> vo 切换落定 ──
  await Future<void>.delayed(const Duration(seconds: 4));
  await _snapshot(native, 'after_settle');

  _phase('ready'); // ★ 驱动看到这行才开始截图

  // ── 保持播放，给驱动截图窗口 ──
  final half = (_holdSeconds / 2).round();
  await Future<void>.delayed(Duration(seconds: half));
  await _snapshot(native, 'mid_hold');

  final rest = _holdSeconds - half;
  if (rest > 0) await Future<void>.delayed(Duration(seconds: rest));

  await _snapshot(native, 'end_hold');

  // ── 收尾 ──
  await _dumpLogs(player);
  logSub.cancel();
  try {
    await player.dispose().timeout(const Duration(seconds: 10));
  } catch (_) {}

  _phase('done');
  _finish(0);
}

Future<void> _dumpLogs(Player player) async {
  _section('MPV LOG (${_mpvlog.length} lines)');
  for (final l in _mpvlog) {
    _emit('  $l');
  }
}

// ─────────────────────────────────────────────────────────────
// 单出口：**先同步写盘再退出**
//
// ★ exit() 不展开 finally，所以绝不能把写盘放在 finally 里等它跑。
// ─────────────────────────────────────────────────────────────
void _finish(int code) {
  try {
    final p = '$_workDir/t285_report.txt';
    File(p).writeAsStringSync(_rep.toString());
  } catch (e) {
    debugPrint('$kTag report write failed: $e');
  }
  debugPrint('$kTag EXIT code=$code');
  exit(code);
}
