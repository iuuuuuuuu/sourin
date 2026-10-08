/*
 * t98_codec_probe.dart — 硬指标① 的唯一空白：AC3 / DTS / ASS 的真机取证
 * owner: lead
 *
 * # 为什么需要这个探针
 *
 * 硬指标① 是「HEVC 硬解（含 AC3/DTS 音频 + ASS 字幕）」。
 * 到 2026-09-29 为止，三块里只有 **HEVC 视频硬解**有真机实测证据
 * （`.probe\live-run.log` 里 `d3d11va-copy（就绪=是）` 出现 16 次）。
 * **AC3 / DTS / ASS 从来没有被真跑过。**
 *
 * 唯一的历史仪器 `.probe\probe_entries\codec_matrix_probe.dart` 有两个致命问题：
 *   ① 它把素材名写死成 `t_ac3.mkv` / `t_dts.mkv` —— **这两个文件不存在**，
 *      所以它跑起来只会打印「文件不存在」。
 *   ② 全 `.probe` 树里搜不到它的任何播放日志。
 * 所以它**只能当参考，不能当证据**。
 *
 * # 这个探针要回答什么
 *
 * 四个素材（真值来自 `.probe\t97_sub_extract.txt`，ffprobe 实测，**不是文件名**）：
 *
 * | 素材 | 视频 | 音频 | 字幕轨 |
 * |---|---|---|---|
 * | `hevc_dts_ass.mkv`      | hevc | **dts** | **ass** lang=chi |
 * | `hevc_ac3_ass_sub.mkv`  | hevc | **ac3** | **ass** lang=chi |
 * | `hevc_with_sub.mp4`     | hevc | **ac3** | mov_text lang=chi |
 * | `hevc_ac3_ass.mp4`      | hevc | **ac3** | ★ **没有字幕轨** |
 *
 * ★★★ 最后一行是**命名陷阱**：文件名带 `_ass` 却一条字幕轨都没有。
 *     我把它留下来当**阴性对照** —— 这是本探针最重要的设计决定。
 *
 * # 判据（为什么这样设计）
 *
 * ① 音频：mpv/FFmpeg 内部把 **DTS 叫 `dca`**（老探针 `:243-258` 记过这件事）。
 *    所以判据是**别名表**而不是字符串相等：
 *    `dts → ['dts','dca']` / `ac3 → ['ac3','a52']`。
 *    只断言「audio-codec 非空」是**恒真式** —— 任何音频都能过。
 *
 * ② 字幕：**「能枚举到轨」离「屏幕上有字」还差三步**
 *    （选轨 → libass 解析 → 渲染上屏）。
 *    老探针用 `sub-text` 非空当证据 —— 那是**读值**，不是**像素**。
 *
 *    本探针用**同一帧差分**：
 *      暂停在同一时刻 → 截一张（sub-visibility=yes）
 *                      → 截一张（sub-visibility=no）
 *                      → 两图之差 = 字幕像素
 *    视频内容被差分**完全消掉**，所以判据不依赖任何固定颜色，
 *    也不需要"画面里恰好有某个颜色"。
 *
 *    ★ 但差分只证明"有东西"，不证明"渲染器执行了 ASS 样式"。
 *      所以对 ASS 素材**再加一层**：给**每一句**指定期望主色。
 *      第 2 句的行内 `{\c&H00FF00&}` 把颜色覆盖成**绿** ——
 *      那个绿色**只可能来自 ASS 脚本本身**，画面里没有任何东西能伪装成它。
 *      这是"渲染器有没有正确执行**行内样式覆盖**"级别的证据。
 *
 * ③ 阴性对照（本探针的仪器灵敏度自证）：
 *    `hevc_ac3_ass.mp4` 没有任何字幕轨 ⇒ 它的差分**必须 ≈ 0**。
 *    若它也有几千像素"差异"，说明我的差分在测别的东西（噪声/抖动），
 *    整份读数作废 —— 这是上一轮离线判据连错三次换来的纪律
 *    （教训 #392：判据必须对**被测对象**敏感，而不是对画面里恰好有的东西敏感）。
 *
 * # 为什么不用 lib\ui\player_page.dart 的探针钩子
 *
 * `player_page.dart` 里**没有**读 mpv 属性的钩子（13 个 `debugPlayer*` 全是
 * 打开面板/推位置/读计数）。而那个文件当前归 task-77（blocked_by task-67），
 * **不能改**。
 *
 * 但也不需要改：`lib\delivery_test.dart:801-806` 证明探针可以
 * **自己 new 一个 Player** 并直接 `native.getProperty(...)`。
 * 所以本探针的 Player **逐字复刻生产配置**（见 `_newPlayer`），
 * 而不是去动生产文件。
 *
 * # 为什么必须渲染一个真实的 Video widget
 *
 * `delivery_test.dart:1886-1890` 记录过：不渲染的话
 * `setProperty` / `open` 会**永久阻塞且不报错**。
 * 所以 `_Stage` 就是真实播放器页的最小形态。
 *
 * # 运行
 *
 * 必须在含 `libmpv-2.dll` 的目录里跑（照 `.probe\T72P_run\` 复制 `.probe\T98_run\`）。
 * 产物：`.probe\t98_codec_probe.txt` + `.probe\t98-*.png`
 * 退出码：0 = 全部判据通过；1 = 有失败；2 = 环境不可用（拒绝给出读数）
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

// ─────────────────────────────────────────────────────────────
// 产物与输出
// ─────────────────────────────────────────────────────────────

const String _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';
const String _fixtureDir = r'D:\WishProject\sourin-flutter-spike';
const String _art = '$_outDir\\t98_codec_probe.txt';

final List<String> _buf = <String>[];
int _pass = 0;
int _fail = 0;

void _say(String s, {bool? ok}) {
  final mark = ok == null ? '   ' : (ok ? ' ✓ ' : ' ✗ ');
  if (ok == true) _pass++;
  if (ok == false) _fail++;
  final line = ok == null ? s : '$mark$s';
  _buf.add(line);
  debugPrint('[T98] $line');
}

void _head(String s) {
  _buf.add('');
  _buf.add('── $s ──');
  debugPrint('[T98] ── $s ──');
}

Future<void> _waitMs(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// 真进程里的「等一帧」。
/// ★ 必须带 timeout —— 上一轮踩过：没有 timeout 时它会**静默挂住**。
Future<void> _pump([int n = 1]) async {
  for (var i = 0; i < n; i++) {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame
        .timeout(const Duration(seconds: 2), onTimeout: () {});
  }
}

// ─────────────────────────────────────────────────────────────
// 素材真值（来自 ffprobe，不是文件名）
// ─────────────────────────────────────────────────────────────

class _Fixture {
  const _Fixture({
    required this.file,
    required this.audioAliases,
    required this.audioLabel,
    required this.expectRealSubs,
    required this.subKind,
    required this.seekMs,
    required this.expectWindow,
    required this.expectColor,
    required this.isNegativeControl,
  });

  final String file;

  /// mpv 内部名（DTS 叫 dca、AC3 也叫 a52）—— 判据用别名表
  final List<String> audioAliases;
  final String audioLabel;

  /// 真实字幕轨条数（不含 mpv 的伪轨道 auto / no）
  final int expectRealSubs;
  final String subKind;

  /// 在哪一刻做字幕像素差分（ASS 三句：0.01-6.01 / 6.01-12.01 / 12.01-20.01）
  final int seekMs;

  /// ★ 仪器自检：暂停后 position **必须**落在这句台词的时间窗内。
  ///   否则「差分 = 0」只说明我停在了一句没字幕的时刻，**不说明字幕没渲染**。
  ///   null = 阴性对照（没有字幕轨，不适用）。
  final List<int>? expectWindow;

  /// 期望主色：'yellow' | 'green' | 'any' | 'none'
  final String expectColor;

  /// ★ 阴性对照：该素材**没有**字幕轨 ⇒ 差分必须 ≈ 0
  final bool isNegativeControl;
}

const List<_Fixture> _fixtures = <_Fixture>[
  _Fixture(
    file: 'hevc_dts_ass.mkv',
    audioAliases: <String>['dts', 'dca'],
    audioLabel: 'DTS',
    expectRealSubs: 1,
    subKind: 'ass',
    seekMs: 9000, // 第 2 句：行内 {\c&H00FF00&} 覆盖成绿色
    expectWindow: <int>[6010, 12010], // 第 2 句 6.01→12.01
    expectColor: 'green',
    isNegativeControl: false,
  ),
  _Fixture(
    file: 'hevc_ac3_ass_sub.mkv',
    audioAliases: <String>['ac3', 'a52'],
    audioLabel: 'AC3',
    expectRealSubs: 1,
    subKind: 'ass',
    seekMs: 3000, // 第 1 句：样式默认色（黄）
    expectWindow: <int>[10, 6010], // 第 1 句 0.01→6.01
    expectColor: 'yellow',
    isNegativeControl: false,
  ),
  _Fixture(
    file: 'hevc_with_sub.mp4',
    audioAliases: <String>['ac3', 'a52'],
    audioLabel: 'AC3',
    expectRealSubs: 1,
    subKind: 'mov_text',
    seekMs: 2000, // mov_text 第 1 句 0.50-4.00
    expectWindow: <int>[500, 4000],
    expectColor: 'any',
    isNegativeControl: false,
  ),
  _Fixture(
    file: 'hevc_ac3_ass.mp4',
    audioAliases: <String>['ac3', 'a52'],
    audioLabel: 'AC3',
    expectRealSubs: 0,
    subKind: 'none',
    seekMs: 3000,
    expectWindow: null, // 没有字幕轨，窗口不适用
    expectColor: 'none',
    isNegativeControl: true,
  ),
];

// ─────────────────────────────────────────────────────────────
// 截图与像素判据
// ─────────────────────────────────────────────────────────────

final GlobalKey _stageKey = GlobalKey();

Future<ui.Image?> _grab() async {
  final ctx = _stageKey.currentContext;
  if (ctx == null) return null;
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    debugPrint('[T98] 根元素不是 RenderRepaintBoundary: ${ro.runtimeType}');
    return null;
  }
  return ro.toImage(pixelRatio: 1.0);
}

class _Shot {
  _Shot(this.bytes, this.w, this.h);
  final Uint8List bytes;
  final int w;
  final int h;

  int get pixels => w * h;
}

Future<_Shot?> _shotBytes() async {
  final img = await _grab();
  if (img == null) return null;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = img.width, h = img.height;
  img.dispose();
  if (data == null) return null;
  return _Shot(data.buffer.asUint8List(), w, h);
}

Future<int> _savePng(String name) async {
  final img = await _grab();
  if (img == null) return -1;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  if (data == null) return -1;
  final f = File('$_outDir\\t98-$name.png');
  await f.writeAsBytes(data.buffer.asUint8List());
  return data.lengthInBytes;
}

/// 颜色计数（在一张图上直接数，不是在差分图上数）
class _Colors {
  int yellow = 0, green = 0, white = 0, dark = 0, other = 0;
  int get total => yellow + green + white + dark + other;
}

_Colors _classify(_Shot s, int x0, int y0, int x1, int y1) {
  final c = _Colors();
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * s.w + x) * 4;
      final r = s.bytes[i], g = s.bytes[i + 1], b = s.bytes[i + 2];
      if (r > 170 && g > 170 && b < 130) {
        c.yellow++;
      } else if (g > 140 && r < 150 && b < 150) {
        c.green++;
      } else if (r > 190 && g > 190 && b > 190) {
        c.white++;
      } else if (r < 80 && g < 80 && b < 80) {
        c.dark++;
      } else {
        c.other++;
      }
    }
  }
  return c;
}

class _Diff {
  int n = 0;
  int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
}

/// 逐像素差分（只在**字幕区域**找：下半屏 —— ASS Alignment=2 + MarginV=80）
_Diff _diff(_Shot a, _Shot b) {
  final d = _Diff();
  if (a.w != b.w || a.h != b.h) return d;
  // 只看下半屏：字幕在底部（Alignment=2），把上半屏排除可以少受噪声影响
  final yStart = (a.h * 0.5).round();
  for (var y = yStart; y < a.h; y++) {
    for (var x = 0; x < a.w; x++) {
      final i = (y * a.w + x) * 4;
      final dr = (a.bytes[i] - b.bytes[i]).abs();
      final dg = (a.bytes[i + 1] - b.bytes[i + 1]).abs();
      final db = (a.bytes[i + 2] - b.bytes[i + 2]).abs();
      if (dr + dg + db > 40) {
        d.n++;
        if (x < d.minX) d.minX = x;
        if (x > d.maxX) d.maxX = x;
        if (y < d.minY) d.minY = y;
        if (y > d.maxY) d.maxY = y;
      }
    }
  }
  return d;
}

// ─────────────────────────────────────────────────────────────
// 播放器
// ─────────────────────────────────────────────────────────────

/// ★★★ 逐字复刻生产配置 —— 见 `lib\ui\player_page.dart:1391-1447`
/// 唯一允许的差异是注释：生产里 `libass: true` 是 ASS 字幕的唯一开关，
/// media_kit **默认关闭**，不开的话字幕**完全不显示**（不是不好看，是没有）。
Player _newPlayer() => Player(
      configuration: const PlayerConfiguration(
        libass: true,
        bufferSize: 32 * 1024 * 1024,
      ),
    );

/// 等 `pred` 为真；返回是否等到。**必须有 timeout**。
Future<bool> _waitUntil(
  bool Function() pred, {
  Duration timeout = const Duration(seconds: 25),
  String label = '',
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (pred()) return true;
    await _pump(1);
    await _waitMs(100);
  }
  if (label.isNotEmpty) debugPrint('[T98] 等待超时: $label (${sw.elapsedMilliseconds}ms)');
  return false;
}

Future<String> _prop(NativePlayer n, String name) async {
  try {
    final v = await n.getProperty(name).timeout(const Duration(seconds: 10));
    return v;
  } catch (e) {
    return '(读失败:$e)';
  }
}

// ─────────────────────────────────────────────────────────────
// 舞台：真实播放器页的最小形态
// ─────────────────────────────────────────────────────────────

class _Stage extends StatefulWidget {
  const _Stage({required this.controller, required this.player, required this.onReady});
  final VideoController controller;
  final Player player;
  final VoidCallback onReady;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final n = widget.player.platform;
      if (n is NativePlayer) {
        // ★ 生产 `player_page.dart:1567`：硬解必须显式设，PlayerConfiguration 没有这个字段
        await n.setProperty('hwdec', 'auto-safe');
        await n.setProperty('sub-visibility', 'yes');
      }
      widget.onReady();
    });
  }

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: RepaintBoundary(
          key: _stageKey,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: widget.controller, controls: NoVideoControls),
              ),
            ),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// 主流程
// ─────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('[T98] MediaKit.ensureInitialized 失败: $e');
    try {
      MediaKit.ensureInitialized(libmpv: '${Directory.current.path}\\libmpv-2.dll');
    } catch (e2) {
      debugPrint('[T98] 二次尝试也失败: $e2');
      _buf.add('REFUSING: libmpv 不可用 —— 环境不可用，拒绝给出读数');
      await _write();
      exit(2);
    }
  }

  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1280, 800));

  _buf.add('t98 codec probe — 硬指标① 的 AC3 / DTS / ASS 真机取证');
  _buf.add('generated = ${DateTime.now().toIso8601String()}');
  _buf.add('cwd = ${Directory.current.path}');

  // ── 素材存在性（缺一个就拒绝，不给出"看起来跑过了"的读数）──
  _head('素材');
  var missing = 0;
  for (final f in _fixtures) {
    final p = File('$_fixtureDir\\${f.file}');
    final ok = p.existsSync();
    if (!ok) missing++;
    _buf.add('  ${f.file}  ${ok ? "${p.lengthSync()} B" : "★ 缺失"}');
  }
  if (missing > 0) {
    _buf.add('REFUSING: $missing 个素材缺失 —— 拒绝给出读数');
    await _write();
    exit(2);
  }

  var ready = false;
  final done = Completer<void>();
  late Player player;
  late VideoController controller;

  player = _newPlayer();
  controller = VideoController(player);

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Stage(
        controller: controller,
        player: player,
        onReady: () {
          ready = true;
          if (!done.isCompleted) done.complete();
        },
      ),
    ),
  );

  await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
  if (!ready) {
    _buf.add('REFUSING: 舞台没有就绪 —— 无法渲染 Video widget');
    await _write();
    exit(2);
  }
  await _pump(3);

  final native = player.platform;
  if (native is! NativePlayer) {
    _buf.add('REFUSING: platform 不是 NativePlayer (${native.runtimeType})');
    await _write();
    exit(2);
  }
  _say('platform = NativePlayer ✓');

  // ── 逐素材取证 ──
  for (final f in _fixtures) {
    _head('${f.file}  (期望音频=${f.audioLabel} / 字幕=${f.subKind} / 真实轨=${f.expectRealSubs})');

    final path = '$_fixtureDir\\${f.file}'.replaceAll(r'\', '/');
    final url = 'file:///$path';

    var dur = Duration.zero;
    var pos = Duration.zero;
    final s1 = player.stream.duration.listen((d) {
      if (d > dur) dur = d;
    });
    final s2 = player.stream.position.listen((p) {
      if (p > pos) pos = p;
    });

    try {
      await native.setProperty('sub-visibility', 'yes');
      await player.open(Media(url), play: true);
    } catch (e) {
      _say('open 失败: $e', ok: false);
      await s1.cancel();
      await s2.cancel();
      continue;
    }

    final playing = await _waitUntil(
      () => dur > Duration.zero && pos > Duration.zero,
      timeout: const Duration(seconds: 30),
      label: '${f.file} 起播',
    );
    _say('真的在解码（duration=${dur.inMilliseconds}ms position=${pos.inMilliseconds}ms）', ok: playing);

    // ★★★ hwdec-current 必须在 **open 之后、解码器建起来之后** 读
    // （`player_page.dart:2312-2318`：open 之前读永远是空字符串）
    final hw = await _prop(native, 'hwdec-current');
    final vcodec = await _prop(native, 'video-codec');
    final acodec = await _prop(native, 'audio-codec');
    final aparams = await _prop(native, 'audio-params');
    final w = await _prop(native, 'width');
    final h = await _prop(native, 'height');

    _buf.add('  video-codec   = "$vcodec"   ${w}x$h');
    _buf.add('  audio-codec   = "$acodec"');
    _buf.add('  audio-params  = "$aparams"');
    _buf.add('  hwdec-current = "$hw"');

    // ① 视频
    _say('视频编码是 hevc',
        ok: vcodec.toLowerCase().contains('hevc') || vcodec.toLowerCase().contains('h265'));
    _say('硬解生效（hwdec-current 非空且不是 no）', ok: hw.isNotEmpty && hw != 'no');

    // ② 音频（别名表 —— DTS 在 mpv 内部叫 dca）
    final al = acodec.toLowerCase();
    final audioOk = f.audioAliases.any((a) => al.contains(a));
    _say('音频编码是 ${f.audioLabel}（别名 ${f.audioAliases.join("/")}）', ok: audioOk);
    _say('音频参数非空（有采样率/声道）', ok: aparams.trim().isNotEmpty && aparams.trim() != '{}');

    // ③ 字幕轨
    final subs = player.state.tracks.subtitle;
    final realSubs = subs.where((s) => s.id != 'auto' && s.id != 'no').toList();
    _buf.add('  字幕轨 ${subs.length} 条（伪轨道 auto/no ${subs.length - realSubs.length} 条）'
        ' / 音轨 ${player.state.tracks.audio.length} 条');
    _say('真实字幕轨 ${realSubs.length} 条 == 期望 ${f.expectRealSubs}',
        ok: realSubs.length == f.expectRealSubs);

    if (realSubs.isNotEmpty) {
      await player.setSubtitleTrack(const SubtitleTrack('auto', null, null));
      await _waitMs(400);
    }

    // ── 字幕像素差分 ──
    await player.seek(Duration(milliseconds: f.seekMs));
    await _waitMs(1200);
    await player.pause();
    await _pump(4);
    await _waitMs(600);
    await _pump(2);

    final nowMs = player.state.position.inMilliseconds;
    final subText = await _prop(native, 'sub-text');
    final subVis = await _prop(native, 'sub-visibility');
    final sid = await _prop(native, 'sid');
    final trackCount = await _prop(native, 'track-list/count');
    _buf.add('  seek → position=${nowMs}ms  sub-visibility="$subVis"  sid="$sid"  track-list/count=$trackCount');
    _buf.add('  sub-text = "${subText.length > 60 ? "${subText.substring(0, 60)}…" : subText}"');

    /*
     * ★★★ 仪器自检：暂停后真的落在「这句台词」的时间窗里吗？
     *
     * # 为什么必须有这一步
     *
     * 如果 seek 落到了两句台词之间的空隙，那么"差分 = 0"只说明
     * **我停错了地方**，完全不说明字幕没渲染。
     *
     * 这与上一轮离线判据连错三次是同一类错误 —— 教训 #394：
     * 「判据失败时先怀疑自己的期望值」。
     * 把这条自检写进探针，就不必靠人记得去怀疑。
     */
    if (f.expectWindow != null) {
      final lo = f.expectWindow![0], hi = f.expectWindow![1];
      final inWin = nowMs >= lo && nowMs <= hi;
      _say('★ 仪器自检：暂停位置 ${nowMs}ms 落在台词窗口 [$lo, $hi] 内', ok: inWin);
      if (!inWin) {
        _buf.add('  ★★ 位置在台词窗口外 ⇒ 本素材的「差分 = 0」不构成证据，'
            '不能写成「字幕没渲染」');
      }
    }

    final onShot = await _shotBytes();
    final pngOn = await _savePng('${f.file.replaceAll(".", "_")}-on');

    await native.setProperty('sub-visibility', 'no');
    await _pump(4);
    await _waitMs(500);
    await _pump(2);
    final offShot = await _shotBytes();
    final pngOff = await _savePng('${f.file.replaceAll(".", "_")}-off');

    // 复原，别把状态带到下一个素材
    await native.setProperty('sub-visibility', 'yes');
    await _pump(2);

    if (onShot == null || offShot == null) {
      _say('截图失败（on=${onShot != null} off=${offShot != null}）', ok: false);
    } else {
      final d = _diff(onShot, offShot);
      final ratio = d.n / onShot.pixels;
      _buf.add('  截图 on=${pngOn}B off=${pngOff}B  画布 ${onShot.w}x${onShot.h} (${onShot.pixels} px)');
      _buf.add('  差分像素 = ${d.n}  (${(ratio * 100).toStringAsFixed(3)}% of canvas)'
          '${d.maxX >= 0 ? "  bbox=x ${d.minX}..${d.maxX}, y ${d.minY}..${d.maxY}" : ""}');

      if (f.isNegativeControl) {
        // ★★ 阴性对照：没有字幕轨 ⇒ 差分必须 ≈ 0
        // 阈值 0.05% of canvas（1280x800 ⇒ 512 px）。给得比"任何真字幕"小得多，
        // 所以它测的是"我的仪器有没有在测噪声"。
        final thr = (onShot.pixels * 0.0005).round();
        _say('★ 阴性对照：无字幕轨 ⇒ 差分 ${d.n} px 应 ≈ 0（阈值 $thr px）', ok: d.n <= thr);
        if (d.n > thr) {
          _buf.add('  ★★ 阴性对照失败 ⇒ 本探针的差分在测别的东西，'
              '**同一份报告里所有字幕读数都不可信**');
        }
      } else {
        _say('字幕像素真的出现在画面上（差分 ≥ 500 px）', ok: d.n >= 500);

        if (d.n >= 500) {
          // 字幕区域：差分 bbox 向下取整，直接在那块区域上数颜色
          final y0 = (d.minY - 10).clamp(0, onShot.h - 1);
          final y1 = (d.maxY + 10).clamp(1, onShot.h);
          final x0 = (d.minX - 10).clamp(0, onShot.w - 1);
          final x1 = (d.maxX + 10).clamp(1, onShot.w);
          final c = _classify(onShot, x0, y0, x1, y1);
          _buf.add('  字幕区(${x1 - x0}x${y1 - y0}) 颜色：黄=${c.yellow} 绿=${c.green} '
              '白=${c.white} 暗=${c.dark} 其他=${c.other}');

          if (f.expectColor == 'green') {
            // ★★★ 最强证据：行内 {\c&H00FF00&} 覆盖只可能来自 ASS 脚本
            _say('★ 第 2 句行内样式覆盖生效 ⇒ 绿色像素 ${c.green} 是主色',
                ok: c.green >= d.n * 0.10);
          } else if (f.expectColor == 'yellow') {
            _say('第 1 句样式默认色 ⇒ 黄色像素 ${c.yellow} 是主色',
                ok: c.yellow >= d.n * 0.10);
          } else {
            _say('字幕区有非暗色像素（有字）',
                ok: (c.yellow + c.green + c.white) >= d.n * 0.10);
          }
          // 描边：ASS 有 Outline=4，字幕像素里必有暗色
          _say('有描边（暗色像素 ≥ 10%）', ok: c.dark >= d.n * 0.10);
        }
      }
    }

    await s1.cancel();
    await s2.cancel();
    await player.stop();
    await _waitMs(300);
  }

  await player.dispose();
  await _write();

  _buf.add('');
  _buf.add('══════ 结束 pass=$_pass fail=$_fail ══════');
  await _write();
  debugPrint('[T98] RESULT pass=$_pass fail=$_fail');
  exit(_fail == 0 ? 0 : 1);
}

Future<void> _write() async {
  try {
    await File(_art).writeAsString('${_buf.join("\n")}\n');
  } catch (e) {
    debugPrint('[T98] 写产物失败: $e');
  }
}
