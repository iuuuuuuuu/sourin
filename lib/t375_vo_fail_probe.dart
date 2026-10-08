// t375 -- does the product already SEE the "video output failed" condition?
//
// The question
// ------------
// `dist-deliver/README-交付说明.md` and the Owner note both assert, as fact:
//
//   输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默。
//
// That is a claim about behaviour, so it needs a reading rather than a
// recollection. `lib/ui/player_page.dart` already subscribes to
// `player.stream.error` (`_bindPlayerStreams`), and media_kit forwards a log
// message to that stream when `level == 'error'` **and** the prefix is one of
// file / ffmpeg(tcp:) / vd / ad / cplayer / stream. mpv's VO-init failure is
// emitted with prefix `cplayer`:
//
//   [cplayer] Error opening/initializing the selected video_out (--vo) device.
//
// ⇒ either the product already surfaces it (and the docs are wrong), or the
//   message does not reach that channel (and the docs are right).
//
// Method
// ------
// Use the PRODUCT's own video configuration -- `VideoController(player)` with
// no explicit `vo`/`hwdec`, i.e. media_kit's Android defaults (vo=gpu,
// opengl-es=yes, gpu-context=android). Push a real `Video` widget, because the
// controller only initialises once a native surface exists. Open a local file
// and record for ~25 s:
//   * every `stream.error` event, with elapsed ms,
//   * every log message whose level is 'error' (prefix + text),
//   * the mpv properties that describe the output layer.
//
// Note on `logLevel`: it is raised to `v` so the whole sequence is visible.
// That does NOT change what `stream.error` receives -- media_kit forwards iff
// `level == 'error'`, and raising the log level only ADDS lower-level
// messages; it never removes error-level ones. So this probe measures exactly
// what the product would see.
//
// Exit protocol: `exit(fail == 0 ? 0 : 1)` + a `RESULT pass=N fail=M` line.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

const String kTag = '[T375]';

/// Media to open.
///
/// The path is chosen **at runtime by platform**, not baked in by a
/// `String.fromEnvironment`: that mechanism is compile-time, so a build made
/// for one platform carries the other platform's path and the probe refuses
/// with "media missing" -- a wasted build. `T375_MEDIA` can still override.
const String _kMediaOverride = String.fromEnvironment('T375_MEDIA');

String _pickMedia() {
  if (_kMediaOverride.isNotEmpty) return _kMediaOverride;
  if (Platform.isAndroid) {
    return '/storage/emulated/0/Android/data/app.sourin.sourin_spike/files/'
        'media/t285_osd_test.mkv';
  }
  // Windows / desktop: the local sample the rest of this repo's probes use.
  return r'D:\WishProject\sourin-flutter-spike\hevc_sample.mp4';
}

final String kMedia = _pickMedia();

/// Substrings that identify an output-layer initialisation failure. Several
/// are listed on purpose: which one mpv actually prints is a reading, not an
/// assumption, so the report says WHICH matched.
const List<String> kVoFailPatterns = <String>[
  'video output initialization failed',
  'Error opening/initializing the selected video_out',
  'Failed initializing any suitable GPU context',
  'Could not create a GL context',
  'Could not bind API',
];

/// Properties describing the output layer. `vo-configured` is mpv's own
/// read-only boolean for "the video output is configured and ready" -- if it
/// exists and flips, it is a far more robust detector than log text.
const List<String> kProps = <String>[
  'vo', 'current-vo', 'vo-configured', 'vid', 'wid',
  'width', 'height', 'time-pos', 'eof-reached', 'core-idle',
  'hwdec', 'hwdec-current', 'gpu-context', 'opengl-es',
];

final StringBuffer _rep = StringBuffer();
int _pass = 0;
int _fail = 0;
String _workDir = '';

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

void note(String s) => _emit('  . $s');

Future<String> _prop(NativePlayer n, String key) async {
  try {
    return await n.getProperty(key).timeout(const Duration(seconds: 8));
  } catch (e) {
    return '<read-failed: $e>';
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

// ── 舞台：真渲染 Video widget 的最小形态（controller 初始化依赖它）──
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

  _emit('================================================================');
  _emit('t375  does the product already see "video output failed"?');
  _emit('================================================================');
  _emit('workdir = $_workDir');
  _emit('media   = $kMedia (exists=${File(kMedia).existsSync()})');

  final mediaOk = File(kMedia).existsSync();
  ok('A1 media is present on this device', mediaOk);
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
    configuration: const PlayerConfiguration(
      libass: true,
      logLevel: MPVLogLevel.v,
    ),
  );

  // ── 记录器 ────────────────────────────────────────────────────────
  final errors = <String>[]; // stream.error events
  final errLogs = <String>[]; // log messages with level == 'error'
  final allLogs = <String>[]; // level|prefix|text (capped)
  final sw = Stopwatch()..start();

  player.stream.error.listen((e) {
    final line = 't=${sw.elapsedMilliseconds}ms  $e';
    errors.add(line);
    _emit('STREAM.ERROR @ $line');
  });
  player.stream.log.listen((PlayerLog e) {
    final rec = '${e.level}|${e.prefix}|${e.text}';
    if (allLogs.length < 4000) allLogs.add(rec);
    if (e.level.trim() == 'error') {
      errLogs.add(rec);
      _emit('LOG[error] $rec');
    }
  });

  // ★ 不传 vo / hwdec —— 用 media_kit 的 Android 默认（vo=gpu, opengl-es=yes）
  final controller = VideoController(player);
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

  // ── 起播 ──────────────────────────────────────────────────────────
  final tOpen = sw.elapsedMilliseconds;
  try {
    await player.open(Media(kMedia), play: true);
    _emit('open() returned OK at t=${sw.elapsedMilliseconds}ms');
  } catch (e) {
    _emit('open() THREW at t=${sw.elapsedMilliseconds}ms: $e');
  }

  // ── 观察窗口：每 2.5s 记一次属性，共 ~25s ─────────────────────────
  _emit('');
  _emit('===== 观察窗口（每 2.5s 一次属性快照）=====');
  final samples = <Map<String, String>>[];
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final snap = <String, String>{};
    for (final k in kProps) {
      snap[k] = await _prop(native, k);
    }
    samples.add(snap);
    /*
     * ★ 同时记 Dart 侧能看见的东西。
     *
     * 判据要落在**产品真的能读到**的信号上：mpv 属性读得到，但一个
     * watchdog 更该用 media_kit 已经维护好的 state/stream。这里把两者
     * 并排记下来，才能知道哪一个是可用的闸门。
     *
     * 尤其是 `tracks.video.length`：失败臂上 mpv 的 track-list/count 一直是 0，
     * 若 Dart 侧同样为空，就**不能**用「有视频轨」当「应该有画面」的判据。
     */
    final st = player.state;
    final tr = st.tracks;
    snap['dart_tracks_video'] = '${tr.video.length}';
    snap['dart_tracks_audio'] = '${tr.audio.length}';
    snap['dart_tracks_sub'] = '${tr.subtitle.length}';
    snap['dart_duration_ms'] = '${st.duration.inMilliseconds}';
    snap['dart_width'] = '${st.width}';
    snap['dart_height'] = '${st.height}';
    /*
     * ★ t376 五臂矩阵选定的闸门信号（2026-09-30）：
     *   `hasVideoTrack = state.videoParams.dw != null`
     * 记在这里是为了让本探针的报告**能与 t376 交叉印证** ——
     * 两个独立探针在同一台设备上量同一个信号，读数应一致。
     */
    snap['dart_vp_dw'] = '${st.videoParams.dw}';
    snap['dart_playing'] = '${st.playing}';
    snap['dart_buffering'] = '${st.buffering}';
    snap['dart_completed'] = '${st.completed}';
    _emit('t=${sw.elapsedMilliseconds}ms  '
        'vo=${snap['vo']} current-vo=${snap['current-vo']} '
        'vo-configured=${snap['vo-configured']} wid=${snap['wid']} '
        'w=${snap['width']} h=${snap['height']} pos=${snap['time-pos']}');
    _emit('            DART: vTracks=${snap['dart_tracks_video']} '
        'aTracks=${snap['dart_tracks_audio']} dur=${snap['dart_duration_ms']}ms '
        'w=${snap['dart_width']} h=${snap['dart_height']} '
        'vpDw=${snap['dart_vp_dw']} '
        'playing=${snap['dart_playing']} buffering=${snap['dart_buffering']} '
        'completed=${snap['dart_completed']}');
  }

  // ── 判据 ──────────────────────────────────────────────────────────
  _emit('');
  _emit('===== 判决 =====');

  // 1) 日志里到底有没有「输出层初始化失败」，在哪一级
  String? hitPattern;
  String? hitLevel;
  String? hitLine;
  for (final rec in allLogs) {
    for (final p in kVoFailPatterns) {
      if (rec.contains(p)) {
        hitPattern ??= p;
        hitLevel ??= rec.split('|').first;
        hitLine ??= rec;
        break;
      }
    }
    if (hitPattern != null) break;
  }

  final voFailInLog = hitPattern != null;
  _emit('');
  _emit('T375 VO_FAIL_PATTERN_IN_LOG = ${voFailInLog ? 'yes' : 'no'}');
  if (hitPattern != null) {
    _emit('T375 VO_FAIL_LEVEL          = ${hitLevel ?? ''}');
    _emit('T375 VO_FAIL_PATTERN        = $hitPattern');
    _emit('T375 VO_FAIL_FIRST_LINE     = ${hitLine ?? ''}');
  }
  _emit('T375 STREAM_ERROR_EVENTS     = ${errors.length}');
  _emit('T375 ERROR_LEVEL_LOG_LINES   = ${errLogs.length}');
  for (final e in errLogs.take(12)) {
    _emit('    errlog: $e');
  }

  // 2) stream.error 里有没有收到那条 VO 失败（= 产品能不能看见）
  final forwarded = errors.any((e) =>
      kVoFailPatterns.any((p) => e.contains(p)) ||
      e.contains('video output') ||
      e.contains('video_out'));
  _emit('T375 STREAM_ERROR_HAS_VO_FAILURE = ${forwarded ? 'yes' : 'no'}');

  // 3) vo-configured 是否存在/翻转（更稳健的探针）
  final vcReadings =
      samples.map((s) => s['vo-configured'] ?? '').toList(growable: false);
  final vcUsable = vcReadings.isNotEmpty &&
      !vcReadings.first.startsWith('<read-failed');
  _emit('T375 VO_CONFIGURED_READABLE  = ${vcUsable ? 'yes' : 'no'}'
      '${vcUsable ? '  values=${vcReadings.toSet().toList()}' : ''}');

  _emit('');
  _emit('VERDICT = ${forwarded ? 'PRODUCT-ALREADY-REPORTS'
      : (voFailInLog ? 'PRODUCT-SILENT-ON-A-VISIBLE-FAILURE'
      : 'NO-FAILURE-OBSERVED-ON-THIS-DEVICE')}');

  // 4) Dart 侧哪些信号能当闸门？（决定 watchdog 该读什么）
  _emit('');
  _emit('===== Dart 侧可用信号（决定 watchdog 读什么）=====');
  final dartVid =
      samples.map((s) => s['dart_tracks_video'] ?? '?').toList(growable: false);
  final dartDur = samples
      .map((s) => s['dart_duration_ms'] ?? '?')
      .toList(growable: false);
  final dartPos = samples.map((s) => s['time-pos'] ?? '?').toList(growable: false);
  _emit('DART tracks.video  values=${dartVid.toSet().toList()}');
  _emit('DART duration       values=${dartDur.toSet().toList()}');
  _emit('MPV  time-pos       values=${dartPos.toSet().toList()}');
  /*
   * ★★★ 判据修正（2026-09-30，t376 五臂矩阵之后）
   *
   * 原来写的是 `v != '?' && v != '0' && v != '<read-failed>'` —— **错的**。
   *
   * media_kit 的 `tracks.video` 里**永远有两个哨兵元素**
   * （`VideoTrack.auto()` / `VideoTrack.no()`，见
   * `media_kit-1.2.6/lib/src/player/native/player/real.dart:1711-1713`
   * 以及 `models/track.dart` 里 `Tracks` 的默认值）：
   * ```text
   * length == 2  ⇒ 【没有】真实视频轨（只剩两个哨兵）
   * length  > 2  ⇒ 有真实视频轨
   * ```
   * 于是 `'2'` 被原判据当成"有轨"，打印出 `yes` —— 而真相是 no。
   *
   * t376 的 `win-audio` 臂实测到 `vtrack=2`（纯音频流），
   * `win-video` 臂实测到 `vtrack=3`（真视频），两条读数把这条语义钉死了。
   */
  final videoTrackSeen = dartVid.any((v) {
    final n = int.tryParse(v);
    return n != null && n > 2;
  });
  _emit('DART VIDEO TRACK SEEN = ${videoTrackSeen ? 'yes' : 'no'}'
      '  (判据: length > 2；2 == 只剩 auto/no 两个哨兵 ⇒ 无真实视频轨)');
  _emit(videoTrackSeen
      ? '  => 可用「有视频轨 && vo-configured==no」当闸门（不会误伤音频流）'
      : '  => 失败臂上拿不到视频轨 ⇒ **不能**用它当闸门；'
          '必须另找（例如 videoParams.dw 非空 + vo-configured==no）');

  // 判据：本探针要回答的是「产品能不能看见」，所以只要**能**确定答案就算通过。
  // 若这台设备上根本没发生输出层失败（例如真机/桌面），那是「无信息量」，
  // 不是失败 —— 但也绝不能算通过，否则一个从不触发的探针会永远绿。
  if (!voFailInLog) {
    _emit('');
    _emit('NO READING: this device did not hit a VO init failure in 25s,');
    _emit('  so the question "can the product see it" was NOT exercised here.');
    _emit('  (a probe that never triggers must not report success)');
    ok('B0 the failing condition was actually exercised', false,
        'no VO failure observed -> no information about detectability');
  } else {
    ok('B1 the VO failure IS visible in mpv\'s log at level=error', true,
        'level=${hitLevel ?? ''}');
    ok('B2 media_kit forwards it to stream.error (product can see it)',
        forwarded,
        forwarded ? '' : 'NOT forwarded -> product really is silent');
    ok('B3 vo-configured is readable as a non-log detector', vcUsable,
        vcUsable ? '' : 'not a usable property on this build');
  }

  _emit('');
  _emit('--- stream.error 事件全文（${errors.length} 条）---');
  for (final e in errors) {
    _emit('    $e');
  }
  _emit('--- 观察窗口结束时的属性 ---');
  if (samples.isNotEmpty) {
    final last = samples.last;
    for (final k in kProps) {
      _emit('    $k = ${last[k]}');
    }
  }
  _emit('(open() 调用发生在 t=${tOpen}ms)');

  try {
    await player.dispose().timeout(const Duration(seconds: 10));
  } catch (_) {}

  _finish(0);
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

/// 单出口：先同步写盘再退出（exit() 不展开 finally）。
void _finish(int code) {
  _emit('');
  _emit('RESULT pass=$_pass fail=$_fail');
  try {
    File('$_workDir/t375_report.txt').writeAsStringSync(_rep.toString());
  } catch (e) {
    debugPrint('$kTag report write failed: $e');
  }
  debugPrint('$kTag EXIT code=$code');
  exit(code);
}
