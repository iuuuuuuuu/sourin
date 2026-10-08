// t376 -- WHICH Dart-side signal can serve as the user-visible gate for
//         "the output layer was never built"?
//
// Why this probe exists
// ---------------------
// t375 established, by measurement, that on this box's Android emulator the
// product runs the failing path silently:
//
//   * mpv DOES log `error|vo/gpu/opengl|Could not create a GL context.`
//   * media_kit does NOT forward it to `stream.error` (its forwarding table
//     only covers prefixes file / ffmpeg(tcp:) / vd / ad / cplayer / stream,
//     and this message's prefix is `vo/gpu/opengl`)
//   => `VERDICT = PRODUCT-SILENT-ON-A-VISIBLE-FAILURE`
//
// The product fix needs a detector. A detector must be:
//   (a) TRUE  on an arm where video really is being shown,
//   (b) FALSE on an arm where the output layer failed,
//   (c) FALSE on an arm that legitimately has NO video at all (audio-only),
//       otherwise every radio stream would raise a false alarm.
//
// (c) is the one that is easy to forget, and it is the reason this probe
// measures several candidates side by side instead of assuming one.
//
// This probe therefore records a per-500ms time series of every candidate and
// prints, for each, the first sample at which it became true. Comparing the
// four arms (win-video / win-audio / android-video / android-audio) is what
// selects the gate. The probe deliberately does NOT hard-code a verdict: it
// reports which candidates agreed with `vo-configured`, and the operator
// reads the table across arms.
//
// Arms are selected at RUNTIME through a config file, not through
// `String.fromEnvironment` (which is compile-time, so one build could not
// cover four arms):
//
//   Windows : <cwd>/t376_config.txt
//   Android : <external files dir>/t376_config.txt
//   contents:  label=<arm name>
//              media=<path>
//
// Exit protocol: `exit(fail == 0 ? 0 : 1)` + a `RESULT pass=N fail=M` line.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

const String kTag = '[T376]';

/// Properties describing the output layer, read straight from mpv.
///
/// `vo-configured` is mpv's own read-only boolean for "the video output is
/// configured and ready". It is the closest thing mpv has to the exact
/// semantic we need, so it is included -- but it is only ONE candidate.
const List<String> kMpvProps = <String>[
  'vo', 'current-vo', 'vo-configured', 'vid', 'wid',
  'width', 'height', 'video-params', 'core-idle', 'time-pos', 'eof-reached',
];

final StringBuffer _rep = StringBuffer();
int _pass = 0;
int _fail = 0;
String _workDir = '';
String _label = '(unset)';
String _media = '';
// ★ Empty means "do not override" i.e. the product default. Non-empty values
// come from the arm config and are handed to [VideoControllerConfiguration].
// Needed because the only Android configuration *proven* to render on this
// emulator is `vo=mediacodec_embed` + `hwdec=mediacodec` (t285 arm A), which
// is NOT the product default -- without it there is no "working Android
// video" arm, and the gate would be validated against a Windows success only.
String _vo = '';
String _hwdec = '';

void _emit(String line) {
  _rep.writeln(line);
  // logcat goes ASCII-only: non-ASCII has been mangled on this box's pipes
  debugPrint('$kTag ${line.replaceAll(RegExp(r'[^\x20-\x7E]'), '?')}');
}

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
  }
  _emit('  [${cond ? 'PASS' : 'FAIL'}] $label${extra.isEmpty ? '' : '   $extra'}');
}

Future<String> _prop(NativePlayer n, String key) async {
  try {
    return await n.getProperty(key).timeout(const Duration(seconds: 8));
  } catch (e) {
    return '<read-failed>';
  }
}

Future<String> _resolveWorkDir() async {
  if (Platform.isAndroid) {
    try {
      final d = await getExternalStorageDirectory();
      if (d != null) return d.path;
    } catch (_) {}
    return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files';
  }
  return Directory.current.path;
}

String _defaultMedia() {
  if (Platform.isAndroid) {
    return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files/'
        'media/t285_osd_test.mkv';
  }
  return r'D:\WishProject\sourin-flutter-spike\hevc_sample.mp4';
}

/// Writes a genuine **audio-only** media file and returns its path.
///
/// # Why the probe has to make this itself
///
/// The `android-audio` arm needs a stream that legitimately has no video
/// track. Two obvious routes are both closed on this box:
///   * `adb push` into `/storage/emulated/0/Android/data/<pkg>/files/media/`
///     fails with `remote couldn't create file: Permission denied` -- that
///     directory belongs to the app's uid, which is exactly why the t285
///     media files got there by the app writing them itself.
///   * there is no ffmpeg on the device.
///
/// A 16-bit PCM WAV is ~44 bytes of header plus samples, so the probe can
/// write one directly. A RIFF/WAVE file **cannot** carry a video track, so
/// "this media has no video" is true by construction rather than by
/// assumption -- which is the property the arm depends on.
String _synthAudioWav() {
  final path = '$_workDir/t376_synth_audio.wav';
  const rate = 8000;
  const seconds = 30;
  const samples = rate * seconds;
  const dataBytes = samples * 2; // mono, 16-bit
  final b = BytesBuilder();
  void u32(int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);

  b.add('RIFF'.codeUnits);
  u32(36 + dataBytes);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(rate);
  u32(rate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits
  b.add('data'.codeUnits);
  u32(dataBytes);
  // A quiet 440 Hz tone so the stream is not silence.
  for (var i = 0; i < samples; i++) {
    final s = (3000 * math.sin(i * 440 * 2 * math.pi / rate)).round();
    u16(s < 0 ? s + 65536 : s);
  }
  File(path).writeAsBytesSync(b.takeBytes());
  return path;
}

/// Reads `label=` / `media=` from `<workDir>/t376_config.txt`.
///
/// Returns the raw file text (or a note) so the report shows what was
/// actually consumed -- a config read that silently falls back to defaults
/// is indistinguishable from a config that was never written.
String _loadConfig() {
  final f = File('$_workDir/t376_config.txt');
  if (!f.existsSync()) {
    _label = '(no config file -> defaults)';
    _media = _defaultMedia();
    return '(absent)';
  }
  final text = f.readAsStringSync();
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final k = line.substring(0, i).trim();
    final v = line.substring(i + 1).trim();
    if (k == 'label') _label = v;
    if (k == 'media') _media = v;
    if (k == 'vo') _vo = v;
    if (k == 'hwdec') _hwdec = v;
  }
  if (_media.isEmpty) _media = _defaultMedia();
  // `media=SYNTH_AUDIO` -> a WAV generated on the spot (see _synthAudioWav).
  if (_media == 'SYNTH_AUDIO') _media = _synthAudioWav();
  return text.replaceAll('\n', ' | ').trim();
}

/// One sample. Numeric fields stay numeric so predicates do not parse strings.
class _S {
  _S(this.t);
  final int t; // ms since stopwatch start

  int? dWidth, dHeight, dDurMs, dVTrack;
  int dVpEvents = 0;
  bool dPlaying = false, dBuffering = false, dCompleted = false;
  String dVpFmt = '';
  int? dVpDw, dVpDh;

  bool cReady = false, cFf = false;
  int? cFfAtMs;
  int? cId;
  double? cRectW, cRectH;

  String vo = '', curVo = '', voConf = '', vid = '', wid = '';
  String mWidth = '', mHeight = '', mVideoParams = '', coreIdle = '', timePos = '';
}

/// A named predicate over the sample list, plus the first index where it held.
class _Cand {
  _Cand(this.name, this.desc, this.test);
  final String name;
  final String desc;
  final bool Function(_S s) test;

  int? firstTrueMs;
}

Future<Duration?> _waitFor(Future<bool> Function() pred, Duration timeout,
    {Duration step = const Duration(milliseconds: 250)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    try {
      if (await pred()) return sw.elapsed;
    } catch (_) {}
    await Future<void>.delayed(step);
  }
  return null;
}

class _Stage extends StatelessWidget {
  const _Stage({required this.controller});
  final VideoController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: Video(
            controller: controller,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
        ),
      );
}

Future<void> main() async {
  debugPrint = debugPrintSynchronously;
  WidgetsFlutterBinding.ensureInitialized();
  _workDir = await _resolveWorkDir();

  final cfg = _loadConfig();

  _emit('================================================================');
  _emit('t376  which Dart-side signal gates "the output layer never built"?');
  _emit('================================================================');
  _emit('workdir = $_workDir');
  _emit('label   = $_label');
  _emit('config  = $cfg');
  _emit('media   = $_media (exists=${File(_media).existsSync()})');
  _emit('vo      = ${_vo.isEmpty ? '(product default)' : _vo}');
  _emit('hwdec   = ${_hwdec.isEmpty ? '(product default)' : _hwdec}');

  ok('A0 a config file selected this arm (not a silent default)',
      _label != '(unset)' && _label != '(no config file -> defaults)',
      'label=$_label');

  final mediaOk = File(_media).existsSync();
  ok('A1 media is present', mediaOk);
  if (!mediaOk) {
    _emit('REFUSING: media missing -- the instrument cannot produce a reading');
    _finish(2);
    return;
  }

  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    _emit('REFUSING: MediaKit.ensureInitialized failed: $e');
    _finish(2);
    return;
  }

  final player = Player(
    configuration: const PlayerConfiguration(libass: true),
  );

  final sw = Stopwatch()..start();
  final errEvents = <String>[];
  final errLogs = <String>[];
  var vpEvents = 0;

  player.stream.error.listen((e) => errEvents.add('t=${sw.elapsedMilliseconds}$e'));
  player.stream.log.listen((PlayerLog e) {
    if (e.level.trim() == 'error' && errLogs.length < 40) {
      errLogs.add('${e.prefix}|${e.text}');
    }
  });
  player.stream.videoParams.listen((_) => vpEvents++);

  // ★ Product default video configuration: no explicit vo / hwdec / opengl-es.
  // An arm may override `vo` / `hwdec` via config; empty means "leave it to the
  // product default" (null == let media_kit pick, which is `gpu` on Android).
  final controller = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      vo: _vo.isEmpty ? null : _vo,
      hwdec: _hwdec.isEmpty ? null : _hwdec,
    ),
  );
  runApp(_Stage(controller: controller));

  final ctlOk = await _waitFor(
    () async => controller.notifier.value != null,
    const Duration(seconds: 40),
  );
  ok('A2 VideoController became ready', ctlOk != null,
      ctlOk == null ? '(40s timeout)' : 'after=${ctlOk.inMilliseconds}ms');
  if (ctlOk == null) {
    _finish(2);
    return;
  }

  final native = player.platform;
  if (native is! NativePlayer) {
    _emit('REFUSING: platform is not NativePlayer (${native.runtimeType})');
    _finish(2);
    return;
  }

  // ★ 首帧 Future —— 库自己的「真的画了」信号。挂上 .then，永不完成也如实记录。
  var ffDone = false;
  int? ffAtMs;
  unawaited(controller.waitUntilFirstFrameRendered.then((_) {
    if (!ffDone) {
      ffDone = true;
      ffAtMs = sw.elapsedMilliseconds;
    }
  }).catchError((Object _) {}));

  try {
    await player.open(Media(_media), play: true);
    _emit('open() returned OK at t=${sw.elapsedMilliseconds}ms');
  } catch (e) {
    _emit('open() THREW at t=${sw.elapsedMilliseconds}ms: $e');
  }

  // ── 采样窗口 ───────────────────────────────────────────────────────
  const step = Duration(milliseconds: 500);
  const n = 48; // 24 s
  final samples = <_S>[];

  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(step);
    final s = _S(sw.elapsedMilliseconds);

    final st = player.state;
    s.dWidth = st.width;
    s.dHeight = st.height;
    s.dDurMs = st.duration.inMilliseconds;
    s.dPlaying = st.playing;
    s.dBuffering = st.buffering;
    s.dCompleted = st.completed;
    s.dVTrack = st.tracks.video.length;
    s.dVpFmt = '${st.videoParams.pixelformat}';
    s.dVpDw = st.videoParams.dw;
    s.dVpDh = st.videoParams.dh;
    s.dVpEvents = vpEvents;

    s.cReady = controller.notifier.value != null;
    s.cFf = ffDone;
    s.cFfAtMs = ffAtMs;
    s.cId = controller.id.value;
    s.cRectW = controller.rect.value?.width;
    s.cRectH = controller.rect.value?.height;

    for (final k in kMpvProps) {
      final v = await _prop(native, k);
      switch (k) {
        case 'vo':
          s.vo = v;
        case 'current-vo':
          s.curVo = v;
        case 'vo-configured':
          s.voConf = v;
        case 'vid':
          s.vid = v;
        case 'wid':
          s.wid = v;
        case 'width':
          s.mWidth = v;
        case 'height':
          s.mHeight = v;
        case 'video-params':
          s.mVideoParams = v.length > 90 ? '${v.substring(0, 90)}...' : v;
        case 'core-idle':
          s.coreIdle = v;
        case 'time-pos':
          s.timePos = v;
      }
    }
    samples.add(s);

    if (i % 4 == 0 || i == n - 1) {
      _emit('t=${s.t}ms  vpEv=$vpEvents vo=${s.vo} curVo=${s.curVo} '
          'voConf=${s.voConf} wid=${s.wid} w=${s.mWidth} h=${s.mHeight} '
          'pos=${s.timePos}');
      _emit('            DART w=${s.dWidth} h=${s.dHeight} dur=${s.dDurMs} '
          'vtrack=${s.dVTrack} vpDw=${s.dVpDw} playing=${s.dPlaying} '
          'completed=${s.dCompleted} | CTL id=${s.cId} '
          'rect=${s.cRectW}x${s.cRectH} ff=${s.cFf}');
    }
  }

  // ── 候选信号矩阵 ───────────────────────────────────────────────────
  final cands = <_Cand>[
    _Cand('mpv.vo-configured==yes', "mpv's own 'video output ready' boolean",
        (s) => s.voConf == 'yes'),
    _Cand('mpv.current-vo non-empty', 'the VO that actually took over',
        (s) => s.curVo.isNotEmpty && s.curVo != '<read-failed>'),
    _Cand('mpv.video-params non-empty', 'mpv parsed a video track',
        (s) => s.mVideoParams.isNotEmpty && !s.mVideoParams.startsWith('<')),
    _Cand('state.width != null', 'Dart state carries decoded frame size',
        (s) => s.dWidth != null),
    _Cand('state.videoParams.dw != null', 'Dart VideoParams populated',
        (s) => s.dVpDw != null),
    _Cand('state.tracks.video.length > 2',
        'a REAL video track (2 == only the auto/no sentinels)',
        (s) => (s.dVTrack ?? 0) > 2),
    _Cand('controller.id != null', 'texture id handed to Flutter',
        (s) => s.cId != null),
    _Cand('controller.rect > 1x1', 'surface resized to video size',
        (s) => (s.cRectW ?? 0) > 1.0 && (s.cRectH ?? 0) > 1.0),
    _Cand('waitUntilFirstFrameRendered', 'library says a frame was rendered',
        (s) => s.cFf),
    _Cand('mpv.time-pos non-empty', 'playback clock running',
        (s) => s.timePos.isNotEmpty && !s.timePos.startsWith('<')),
  ];

  for (final c in cands) {
    for (final s in samples) {
      if (c.test(s)) {
        c.firstTrueMs = s.t;
        break;
      }
    }
  }

  _emit('');
  _emit('================ SIGNAL MATRIX (arm = $_label) ================');
  _emit('CANDIDATE                        EVER   FIRST_MS');
  for (final c in cands) {
    final ever = c.firstTrueMs != null ? 'yes' : 'no';
    final at = c.firstTrueMs?.toString() ?? '-';
    _emit('  ${c.name.padRight(30)} $ever   $at');
  }
  _emit('--------------------------------------------------------------');
  for (final c in cands) {
    _emit('  ${c.name}  <=  ${c.desc}');
  }

  // ★ 自描述：本臂「有画面」的基准是 mpv.vo-configured（t375 已在两臂上
  //   10/10 一致）。列出与它**一致**的候选 —— 跨臂比较才能定论，
  //   这里只把一致性摆出来，不下判决。
  final base = cands.first;
  final baseEver = base.firstTrueMs != null;
  final agree = cands
      .where((c) => (c.firstTrueMs != null) == baseEver)
      .map((c) => c.name)
      .toList();
  final disagree = cands
      .where((c) => (c.firstTrueMs != null) != baseEver)
      .map((c) => c.name)
      .toList();
  _emit('');
  _emit('BASE (vo-configured) ever-true = ${baseEver ? 'yes' : 'no'}');
  _emit('AGREE WITH BASE   = ${agree.join(', ')}');
  _emit('DISAGREE WITH BASE= ${disagree.isEmpty ? '(none)' : disagree.join(', ')}');

  _emit('');
  _emit('last sample: vo=${samples.last.vo} curVo=${samples.last.curVo} '
      'voConf=${samples.last.voConf} w=${samples.last.mWidth} '
      'h=${samples.last.mHeight} pos=${samples.last.timePos} '
      'coreIdle=${samples.last.coreIdle}');
  _emit('  raw video-params = ${samples.last.mVideoParams}');
  _emit('  DART: w=${samples.last.dWidth} h=${samples.last.dHeight} '
      'vtrack=${samples.last.dVTrack} vpFmt=${samples.last.dVpFmt} '
      'vpDw=${samples.last.dVpDw} playing=${samples.last.dPlaying} '
      'completed=${samples.last.dCompleted}');
  _emit('  CTL : id=${samples.last.cId} rect=${samples.last.cRectW}'
      'x${samples.last.cRectH} ff=$ffDone ffAt=${ffAtMs}ms');

  _emit('');
  _emit('stream.error events = ${errEvents.length}');
  for (final e in errEvents.take(8)) {
    _emit('    $e');
  }
  _emit('error-level log lines = ${errLogs.length}');
  for (final e in errLogs.take(8)) {
    _emit('    $e');
  }

  // 本探针的判据只关于**仪器本身**：四条臂都跑完才谈得上选闸门，
  // 所以这里只断言「读数拿到了」，不把某个候选写成结论。
  ok('B1 sampling window produced readings', samples.length == n,
      'samples=${samples.length}');
  ok('B2 the output-layer properties were readable',
      samples.last.voConf.isNotEmpty &&
          !samples.last.voConf.startsWith('<read-failed'),
      'vo-configured=${samples.last.voConf}');

  try {
    await player.dispose().timeout(const Duration(seconds: 10));
  } catch (_) {}

  _finish(0);
}

/// 单出口：先同步写盘再退出（exit() 不展开 finally）。
void _finish(int code) {
  _emit('');
  _emit('RESULT pass=$_pass fail=$_fail');
  try {
    final name = _label.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    File('$_workDir/t376_report.txt').writeAsStringSync(_rep.toString());
    File('$_workDir/t376_report_$name.txt').writeAsStringSync(_rep.toString());
  } catch (e) {
    debugPrint('$kTag report write failed: $e');
  }
  debugPrint('$kTag EXIT code=$code');
  exit(code);
}
