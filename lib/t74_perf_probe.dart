/*
 * task-74 ⑤ 整页性能实测 —— 真机（Windows release）取证探针
 *
 * ════════════════════════════════════════════════════════════════════════
 * 为什么必须有这个探针（合成侧做不到的部分）
 * ════════════════════════════════════════════════════════════════════════
 * 合成半（`test/t74_perf_synth_test.dart`，读数在
 * `.probe/t74_perf_synth_rebuild.txt`）在 `flutter test` 里量到：
 *   PA 搜索页 20 hit 重建面 p50=428 p95=428  墙钟 p50=34114us p95=54345us
 *   PB 设置页 **挂不上**（`ErrorWidget=1`，真因缺 `sourin_core.dll`）
 *   PC 追更页 20 条 重建面=562 墙钟=121599us / 滚 200px 重建面=0 墙钟=5070us
 *   PD 直播页 `_groups` 为空 ⇒ `_probeAll` 的逐频道 setState 路径走不到
 *   PE 启动 首帧 254012us/480 重建，到稳定 18 帧 658 重建 335868us
 * ⇒ 设置页滚动、直播页真实数据路径 **只能真机量**。
 *
 * ════════════════════════════════════════════════════════════════════════
 * ★★ 仪器选择：为什么不用 `debugOnRebuildDirtyWidget`（重建面计数）
 * ════════════════════════════════════════════════════════════════════════
 * 它在 release 下被 `assert(() { ... }())` 包住
 * （`.../flutter/lib/src/widgets/framework.dart:5516-5522`）⇒
 * **恒不触发**。不是"偏小"，是恒 0，而且会伪装成「零重建 = 不卡」这种
 * 假绿。所以本探针在真机上只报三类读数：
 *   ① 墙钟（`DateTime` 差值）
 *   ② `FrameTiming.buildDuration` / `rasterDuration`（微秒）
 *   ③ `> 16.7ms` 的帧数（60Hz 预算）
 * 并**必须**配阳性对照（见 `phasePositiveControl`）证明仪器**能**读出卡顿。
 *
 * ════════════════════════════════════════════════════════════════════════
 * 阳性对照为什么用 `scheduleFrameCallback`（transient callback）
 * ════════════════════════════════════════════════════════════════════════
 * `SchedulerBinding.handleDrawFrame` 的相位是：
 *   transient callbacks（`handleBeginFrame` 内）→ persistent callbacks
 *   （`RendererBinding.drawFrame` = build/layout/paint）→ postFrameCallbacks
 * 而 `FrameTiming.buildDuration` 的区间是「beginFrame 开始 → persistent 结束」
 * ⇒ **transient 回调里的耗时会计入 `buildDuration`**（动画 ticker 同理）。
 * 所以在这里注入 200ms 同步忙等，`buildDuration` 的 p95 必须落到 200000us
 * 量级；若仍停在 1ms 量级 ⇒ 结论是「仪器不可信」，不是「不卡」。
 *
 * ════════════════════════════════════════════════════════════════════════
 * 产物（★ 本仓判据是**产物文件**，不是 stdout —— 见 t74_panel_dir_probe.dart
 * 的注释：Windows GUI 子系统程序的输出能否被父进程接住取决于句柄继承）
 * ════════════════════════════════════════════════════════════════════════
 *   .probe\t74_perf_real_startup.txt   启动半
 *   .probe\t74_perf_real_pages.txt     逐页半
 * 每次 `say/ok/note` 都立刻落盘 ⇒ 中途崩了也不丢已采到的读数。
 */

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
import 'core/models.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/follow_page.dart';
import 'ui/live_page.dart';
import 'ui/search_page.dart';
import 'ui/settings_page.dart';
import 'ui/widgets/page_transition.dart';

// ─────────────────────────── 基础设施 ───────────────────────────

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// ══════════════════════════════════════════════════════════════════════
/// 双极对照（task-74 ⑤ 的 raster 地板归因）—— 复用同一份探针代码
/// ══════════════════════════════════════════════════════════════════════
///
/// 判据是「极A.raster_p50 − 极B.raster_p50」。为了让两次跑是**同一把尺**，
/// 两个极跑的都是本文件（逐字同一份源码），只靠 dart-define 区分：
///
/// ```text
/// T74_POLE  = a | b        非空 ⇒ 产物写到 t74_perf_pole_<tag>_*.txt
///                          （**绝不覆盖**交付用的 t74_perf_real_*.txt）
/// T74_PHASE = search,settings
///                          只跑列出的页；空 ⇒ 全部页（原行为）
/// ```
///
/// ★ 为什么要产物分离：`t74_perf_real_startup.txt` / `_pages.txt` 是 ⑤ 的
///   交付读数，双极跑只是**归因实验**，不许把它们冲掉。
/// ★ 双极对照的开关一律读**运行时环境变量**（`--dart-define` 只作兜底）。
/// 理由：`--dart-define` 是**编译期**的 ⇒ 极 A / 极 B 会变成两个不同的二进制，
/// 「同一把尺」就只剩源码层面。改成环境变量后，A / B1 / B2 **跑的是逐字节
/// 同一个 exe**，仪器同一性从"源码相同"升级到"二进制相同"，而且省掉每极一次
/// 77s 重建。
String _envOr(String key, String fallback) {
  final v = Platform.environment[key];
  return (v == null || v.trim().isEmpty) ? fallback : v.trim();
}

/// 窗口尺寸（`T74_SIZE=640x400`）。默认 1280x800 = 原行为，逐字不变。
/// 面积标定实验专用：`1280x800` 的面积是 `640x400` 的 **4 倍**。
final _windowRaw = _envOr('T74_SIZE', '1280x800');

(int, int) _windowSize() {
  final m = RegExp(r'^(\d+)\s*[xX×]\s*(\d+)$').firstMatch(_windowRaw);
  if (m == null) return (1280, 800);
  final w = int.tryParse(m.group(1)!) ?? 1280;
  final h = int.tryParse(m.group(2)!) ?? 800;
  if (w < 200 || h < 200) return (1280, 800);
  return (w, h);
}

const _poleTagDefine = String.fromEnvironment('T74_POLE', defaultValue: '');
final _poleTag = _envOr('T74_POLE', _poleTagDefine);

/// 玻璃极 = 双极对照的**自变量**：
/// ```text
/// ''   极 A  现状，不注入任何东西
/// b1   弱极 GlassAccessibilityScope(reduceTransparency: true)
///          ⇒ adaptive_glass.dart:303-318 IP1 无障碍 fast-path ⇒ _FrostedFallback
///          ★ 只去掉 lightweight fragment shader，**仍然推 BackdropFilter**
/// b2   强极 InheritedLiquidGlass(avoidsRefraction: true)
///          ⇒ adaptive_glass.dart:277 嵌套玻璃 fast-path ⇒ _VibrancyFill
///          ★ 四条 fast-path 里**唯一彻底无 BackdropFilter** 的一条
/// ```
final _glassPole = _envOr('T74_GLASS', '');

/// 直播页入场的 A/B 自变量（⑤ 第 1 项）：
/// ```text
/// on   极 P-on   现状，什么都不做
/// off  极 P-off  **在隔离数据目录里**把全部源禁用 ⇒ get_live_channels 返回空
///                ⇒ live_page.dart:867 `if (groups.isNotEmpty)` 的闸门关上
///                ⇒ `_select()` 不被调用 ⇒ 内嵌播放器**不起播**
/// ```
/// ★ 为什么这条路成立（**零生产代码改动**）：
///   `rust\sourin_core\src\registry.rs:438-444 live_all()` 过滤 `h.enabled`；
///   `commands_provider.rs:40-59 set_enabled_persisted` 既改**运行时** registry
///   又把 id 追加进 `disabled-providers.json` ⇒ 一次调用立刻生效。
/// ★ 生效证据（硬，二者缺一即本极没生效）：
///   ① `getLiveChannels()` 的长度必须从 N 变成 **0**；
///   ② app 日志里**不再出现** `[LIVE] … 取到 N 条线路`。
final _livePole = _envOr('T74_LIVE', 'on');

String get _startupFile => _poleTag.isEmpty
    ? '$_outDir\\t74_perf_real_startup.txt'
    : '$_outDir\\t74_perf_pole_${_poleTag}_startup.txt';
String get _pagesFile => _poleTag.isEmpty
    ? '$_outDir\\t74_perf_real_pages.txt'
    : '$_outDir\\t74_perf_pole_${_poleTag}_pages.txt';

/// 只跑哪些页（空 = 全部）。双极法用 `search,settings`：这两页没有视频、
/// 没有网络图，raster 地板最干净。
const _phaseDefine = String.fromEnvironment('T74_PHASE', defaultValue: '');
final _phases = _envOr('T74_PHASE', _phaseDefine)
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toSet();

bool _want(String phase) => _phases.isEmpty || _phases.contains(phase);

/// 极的注入器：**一行都不用碰生产文件**（注入点就是本文件 `runApp` 的外层）。
/// 三个极共用**同一个 exe**（开关走环境变量）⇒ 仪器同一性从"源码相同"升级到
/// "二进制相同"，也省掉每极一次 ~77s 重建。
Widget _applyGlassPole(Widget child) {
  switch (_glassPole) {
    case 'b1':
      // 弱极：只去掉 lightweight fragment shader，**仍然推 BackdropFilter**
      return GlassAccessibilityScope(reduceTransparency: true, child: child);
    case 'b2':
      // 强极：adaptive_glass.dart:277 嵌套玻璃 fast-path ⇒ _VibrancyFill
      //       （四条 fast-path 里唯一彻底无 BackdropFilter 的一条）
      return InheritedLiquidGlass(
        settings: const LiquidGlassSettings(),
        quality: GlassQuality.standard,
        avoidsRefraction: true,
        child: child,
      );
    case 's':
      // ★ 设置对照极：只改 settings、**不动渲染路径**（avoidsRefraction: false）。
      //   存在的理由：注入 `settings:` 会顶掉 `resolveSettings` 的第 4 级主题兜底
      //   （第 2 级 inherited 优先于第 4 级）⇒ b2 相对极 A 同时改了两个变量。
      //   有了本极才能拆开：(A − s) = 纯设置效应，(s − b2) = 纯渲染路径效应。
      return InheritedLiquidGlass(
        settings: const LiquidGlassSettings(),
        quality: GlassQuality.standard,
        avoidsRefraction: false,
        child: child,
      );
    default:
      return child; // 极 A = 现状，逐字不改
  }
}

/// ★ 极的**生效证据**：直接数渲染路径的类名。
/// `_VibrancyFill` / `_FrostedFallback` 是包内私有类 ⇒ 只能用 runtimeType 字符串
/// 数；但这恰好是"渲染路径真的换了"的直接证据，比"跑完没报错"强得多。
/// （本轮教训：极 B 若是个空操作，"没报错"会给出假结论。）
Map<String, int> _renderPathCensus() {
  const keys = <String>[
    '_VibrancyFill',
    '_FrostedFallback',
    'BackdropFilter',
    'AdaptiveGlass',
    'LightweightLiquidGlass',
    'RepaintBoundary',
  ];
  final hits = <String, int>{};
  void walk(Element e) {
    final n = e.widget.runtimeType.toString();
    for (final k in keys) {
      if (n.contains(k)) hits[k] = (hits[k] ?? 0) + 1;
    }
    e.visitChildren(walk);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) walk(root);
  return hits;
}

final _rootKey = GlobalKey();
final _startupLog = <String>[];
final _pagesLog = <String>[];
List<String> _cur = _pagesLog;

/// 应用自己打出来的行（`[SHELL]` / `[SETTINGS]` / `[FOLLOW]` …）。
/// 这是「页面真的走了生产路径」的直接证据。
final _appPrints = <String>[];
late final void Function(String?, {int? wrapWidth}) _origDebugPrint;

int pass = 0;
int fail = 0;

/// 首帧截图的指纹（极的生效证据之一）。
String _firstShotDigest = '(未取)';

void _flush() {
  try {
    File(_startupFile).writeAsStringSync('${_startupLog.join('\n')}\n');
    File(_pagesFile).writeAsStringSync('${_pagesLog.join('\n')}\n');
  } catch (_) {
    // 落盘失败不能反过来打断取证
  }
}

void say(String s) {
  _cur.add(s);
  debugPrint('[T74P] $s');
  _flush();
}

void ok(String label, bool cond, [String extra = '']) {
  final line = '$label${extra.isEmpty ? '' : '  $extra'}';
  if (cond) {
    pass++;
    _cur.add('✓ $line');
    debugPrint('[T74P] ✓ $line');
  } else {
    fail++;
    _cur.add('✗ $line');
    debugPrint('[T74P] ✗ $line');
  }
  _flush();
}

void note(String s) {
  _cur.add('· $s');
  debugPrint('[T74P] · $s');
  _flush();
}

void _capturePrint(String? message, {int? wrapWidth}) {
  if (message != null && !message.startsWith('[T74P]') && _appPrints.length < 6000) {
    _appPrints.add(message);
  }
  _origDebugPrint(message, wrapWidth: wrapWidth);
}

// ─────────────────────────── 帧耗时仪器 ───────────────────────────

final _all = <FrameTiming>[];
void _onTimings(List<FrameTiming> t) {
  _all.addAll(t);
  // ★ 每次投递都采一个「帧墙钟 vs DateTime.now()」样本 ⇒ 供 epoch 自检用。
  if (t.isNotEmpty && _clockSamples.length < 200) {
    _clockSamples.add(_ClockSample(_wallUs(t.last), DateTime.now().microsecondsSinceEpoch));
  }
}

int _mark() => _all.length;
List<FrameTiming> _since(int m) => _all.sublist(m);

// ═══════════ 真实时间分箱：修「窗口归属不可信」（⑤ 仪器修法） ═══════════
//
// ★ 为什么要这一节 —— 同一 `app.so` 两跑之间的实测反例：
//   字节相同的 `app.so`、相同 phase、相同数据目录，两次运行的「分段」读数却互相搬家：
//     直播页 0/0/20 → 0/0/21；追更页 0/0/42 → 0/34/0；
//     搜索页 0/0/33 → 0/42/0；设置页 0/0/26 → 0/0/27。
//   页面属性不可能在两跑之间搬家 ⇒ `_mark()`/`_since()` 量的是
//   **onReportTimings 回调在哪一段被触发**，不是**帧发生在哪一段**：
//   帧被攒成一批、在窗口内某个 400ms 段一次性投递，落点随运行变。
//   ⇒ 结论：`_since()` 的分段读数**不可用**；只有整窗 n 与 p50 可用。
// ⇒ 本节按 `FrameTiming.rasterFinishWallTime` 的**真实墙钟**重新分箱，并配三样自检：
//   ① epoch 自检（必需）② `frameNumber` 连续性 ③ 逐帧时间线。
//
// ★ SDK 逐字警告（`platform_dispatcher.dart:2211-2212`）：
//   "This is a raw timestamp in microseconds from some epoch. The epoch in all
//    [FrameTiming] is the same, but it may not match [DateTime]'s epoch."
//   ⇒ **epoch 自检是必需项**：不同 epoch 就如实报「分箱做不到」，绝不假装成功。
// ★ SDK 逐字（`:2128-2132`）：
//   "When the raster thread finished rasterizing a frame in wall-time. This is
//    useful for correlating time raster finish time with the system clock to
//    integrate with other profiling tools."

int _wallUs(FrameTiming t) =>
    t.timestampInMicroseconds(ui.FramePhase.rasterFinishWallTime);

int _minOf(List<int> xs) {
  if (xs.isEmpty) return 0;
  var m = xs.first;
  for (final x in xs) {
    if (x < m) m = x;
  }
  return m;
}

/// 某一时刻「最近一帧的墙钟」与「DateTime.now()」的一对采样。
class _ClockSample {
  const _ClockSample(this.wallUs, this.nowUs);
  final int wallUs;
  final int nowUs;
  int get offsetUs => wallUs - nowUs;
}

final _clockSamples = <_ClockSample>[];

/// epoch 自检结果：`null` = 还没测过。
bool? _epochSame;

/// 自检文本是否已经打印过（判据会随样本增多而刷新，但产物里只留一条）。
bool _epochPrinted = false;

/// ★★ 判据必须是**偏移量的绝对量级**，不是"两次采样之间的漂移"。
///
/// 第一版拿「采样间漂移」当判据 ⇒ 把**回调投递延迟抖动**误判成 epoch 不同源：
/// 同一个二进制两次跑，一次报"同源"（漂移 +45.5ms）、一次报"不同源"（漂移 −352.9ms），
/// 而两次的 |偏移| 都只有几百毫秒（+0.5ms / −400.8ms）。
///
/// 真正的 epoch 不同源（引擎给"开机起算"的单调钟、DateTime 给 Unix epoch）会差
/// ~1.79e15us（≈56 年），比 1 秒大 **8 个数量级** ⇒ 用 60s 阈值可以干净分开，
/// 而 60s 又比实测的几百毫秒投递抖动大 **5 个数量级**。
///
/// ★ 每次调用都用**当前全部样本**重算（样本随运行累积 ⇒ 判据越跑越准）。
String _epochReport() {
  if (_clockSamples.length < 2) {
    _epochSame = false;
    _epochPrinted = true;
    return '帧墙钟 epoch 自检：样本不足（${_clockSamples.length} 个）⇒ 按真实时间分箱不可用';
  }
  final offsets = [for (final s in _clockSamples) s.offsetUs];
  final minOff = _minOf(offsets);
  final maxOff = _maxOf(offsets);
  final a = _clockSamples.first, b = _clockSamples.last;
  final drift = (b.wallUs - a.wallUs) - (b.nowUs - a.nowUs);
  const cap = 60000000; // 60s
  final same = minOff.abs() < cap && maxOff.abs() < cap;
  _epochSame = same;
  _epochPrinted = true;
  return '帧墙钟 epoch 自检：样本 ${_clockSamples.length} 个；'
      '偏移量 min=${(minOff / 1000).toStringAsFixed(1)}ms '
      'max=${(maxOff / 1000).toStringAsFixed(1)}ms '
      '（|偏移| 全 < 60s ⇒ 同一 epoch；真不同源会差 ~1.79e15us）'
      '；采样间漂移=${(drift / 1000).toStringAsFixed(1)}ms'
      '（★ 这是**回调投递延迟抖动**，不是 epoch 判据）'
      '⇒ ${same ? '**同源时钟，可按真实时间分箱**' : '**不同源 ⇒ 按真实时间分箱做不到（如实报）**'}';
}

/// 按真实墙钟把帧分箱。`anchor` = 窗口起点的 `DateTime`。
void _framesByWall(String label, List<FrameTiming> ts, DateTime anchor,
    {int binMs = 400}) {
  if (ts.isEmpty) {
    note('$label 按真实时间分箱：窗口内没有帧');
    return;
  }
  // ★ 每次都按**当前全部样本**重算判据（样本随运行累积 ⇒ 判据越跑越准），
  //   但自检那一行只在第一次落进产物，避免刷屏。
  final verdict = _epochReport();
  if (!_epochPrinted) {
    _epochPrinted = true;
    note(verdict);
  }
  if (_epochSame != true) {
    note('$label ★ 按真实时间分箱**做不到**：帧墙钟与 DateTime 不同源 '
        '⇒ 本窗口的分段归属不可信，只能看整窗 n/p50。');
    return;
  }
  final a = anchor.microsecondsSinceEpoch;
  final bins = <int, List<FrameTiming>>{};
  for (final t in ts) {
    final k = ((_wallUs(t) - a) / 1000.0 / binMs).floor();
    (bins[k] ??= <FrameTiming>[]).add(t);
  }
  final keys = bins.keys.toList()..sort();
  note('$label 按真实时间分箱（bin=${binMs}ms，锚=窗口起点，锚差='
      '${((_minOf([for (final t in ts) _wallUs(t)]) - a) / 1000.0).toStringAsFixed(1)}ms）：'
      '共 ${keys.length} 个非空箱');
  for (final k in keys) {
    final g = bins[k]!;
    final rs = [for (final t in g) t.rasterDuration.inMicroseconds];
    final bs = [for (final t in g) t.buildDuration.inMicroseconds];
    final jr = rs.where((r) => r > 16700).length;
    note('  [$k] ${k * binMs}~${k * binMs + binMs}ms  n=${g.length}  '
        'raster p50=${_pct(rs, 0.50)} p95=${_pct(rs, 0.95)} max=${_maxOf(rs)} 超=$jr  '
        '| build p50=${_pct(bs, 0.50)} 超=${bs.where((b) => b > 16700).length}');
  }
}

/// `frameNumber` 连续性：跳号 = 直接证据「有帧没被投递 / 被延迟」。
void _frameNumberAudit(String label, List<FrameTiming> ts) {
  if (ts.length < 2) {
    note('$label frameNumber 连续性：样本不足（n=${ts.length}）');
    return;
  }
  final ns = [for (final t in ts) t.frameNumber]..sort();
  var gaps = 0, missing = 0;
  final details = <String>[];
  for (var i = 1; i < ns.length; i++) {
    final d = ns[i] - ns[i - 1];
    if (d > 1) {
      gaps++;
      missing += d - 1;
      if (details.length < 8) details.add('${ns[i - 1]}→${ns[i]}(缺${d - 1})');
    }
  }
  note('$label frameNumber 连续性：首=${ns.first} 末=${ns.last} '
      '跨度=${ns.last - ns.first + 1} 实收=${ns.length} 缺号段=$gaps 共缺=$missing 帧');
  if (details.isNotEmpty) note('  缺号明细（≤8 条）：${details.join('  ')}');
  if (ns.first < 0) {
    note('  ★ 出现 frameNumber<0（-1 = 引擎未提供）⇒ 本窗口不做连续性判断');
  }
}

/// 逐帧时间线（只给关键窗口用，避免刷屏）。
void _frameTimeline(String label, List<FrameTiming> ts, DateTime anchor,
    {int cap = 40}) {
  if (ts.isEmpty) {
    note('$label 逐帧时间线：无帧');
    return;
  }
  final canRel = _epochSame == true;
  note('$label 逐帧时间线（frameNumber | 相对锚ms | build us | raster us），'
      '共 ${ts.length} 帧，只列前 $cap：');
  for (var i = 0; i < ts.length && i < cap; i++) {
    final t = ts[i];
    final rel = canRel
        ? ((_wallUs(t) - anchor.microsecondsSinceEpoch) / 1000.0).toStringAsFixed(1)
        : '?';
    note('  #${t.frameNumber}  +${rel}ms  build=${t.buildDuration.inMicroseconds}  '
        'raster=${t.rasterDuration.inMicroseconds}');
  }
  if (ts.length > cap) note('  …（其余 ${ts.length - cap} 帧略）');
}

int _pct(List<int> xs, double q) {
  if (xs.isEmpty) return 0;
  final s = <int>[...xs]..sort();
  return s[((s.length - 1) * q).round()];
}

int _maxOf(List<int> xs) {
  if (xs.isEmpty) return 0;
  var m = xs.first;
  for (final x in xs) {
    if (x > m) m = x;
  }
  return m;
}

int _sumOf(List<int> xs) {
  var s = 0;
  for (final x in xs) {
    s += x;
  }
  return s;
}

/// 报一个窗口的帧读数。★ 空样本必须显式说明，不能静默当 0。
void _frames(String label, List<FrameTiming> ts) {
  if (ts.isEmpty) {
    note('$label 帧数=0（窗口内没有任何帧 ⇒ 本窗口无读数，不能解释成"不卡"）');
    return;
  }
  final builds = [for (final t in ts) t.buildDuration.inMicroseconds];
  final rasters = [for (final t in ts) t.rasterDuration.inMicroseconds];
  final jb = builds.where((b) => b > 16700).length;
  final jr = rasters.where((r) => r > 16700).length;
  note('$label 帧数=${ts.length}  (n=${ts.length}，p95 的统计意义随 n 变化)');
  note('$label build  微秒: p50=${_pct(builds, 0.50)}  p95=${_pct(builds, 0.95)}  '
      'max=${_maxOf(builds)}  sum=${_sumOf(builds)}  (>16.7ms 的帧 $jb)');
  note('$label raster 微秒: p50=${_pct(rasters, 0.50)}  p95=${_pct(rasters, 0.95)}  '
      'max=${_maxOf(rasters)}  sum=${_sumOf(rasters)}  (>16.7ms 的帧 $jr)');
}

void _firstFrame(String label, List<FrameTiming> ts) {
  if (ts.isEmpty) {
    note('$label 首帧：窗口内没有帧');
    return;
  }
  final f = ts.first;
  note('$label 首帧 build=${f.buildDuration.inMicroseconds}us '
      'raster=${f.rasterDuration.inMicroseconds}us '
      'total=${f.totalSpan.inMicroseconds}us');
}

// ─────────────────────────── Element 树工具 ───────────────────────────

Element? _findElement(bool Function(Widget w) pred) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (pred(e.widget)) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) walk(root);
  return hit;
}

State? _stateOf(Type widgetType) {
  final el = _findElement((w) => w.runtimeType == widgetType);
  return el is StatefulElement ? el.state : null;
}

int _elementCount() {
  var n = 0;
  void walk(Element e) {
    n++;
    e.visitChildren(walk);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) walk(root);
  return n;
}

/// ★ Lead 的线索（是线索不是结论）：生产代码 4 处 `Image.network`，而
/// `cacheWidth`/`cacheHeight`/`ResizeImage`/`precacheImage`/`filterQuality`
/// 在 `lib/` 里**命中 0** ⇒ 所有网络图都按**源分辨率**解码再缩小绘制。
/// 这条只读 `imageCache` 的公开计数，**不碰生产代码**：
/// `currentSizeBytes` 是解码后驻留的字节数 —— 若追更页进场后它按海报张数
/// 线性膨胀到几十 MB，就说明确实压着一堆全分辨率位图。
String _imageCacheLine() {
  final c = PaintingBinding.instance.imageCache;
  final mb = (c.currentSizeBytes / 1024 / 1024).toStringAsFixed(1);
  return 'imageCache: 条目=${c.currentSize}  驻留=${c.currentSizeBytes}B (${mb}MB)  '
      'live=${c.liveImageCount}  上限=${c.maximumSize}/'
      '${(c.maximumSizeBytes / 1024 / 1024).toStringAsFixed(0)}MB';
}

List<ScrollableState> _scrollablesUnder(Element root) {
  final out = <ScrollableState>[];
  void walk(Element e) {
    final s = e is StatefulElement ? e.state : null;
    if (s is ScrollableState) out.add(s);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

// ─────────────────────────── 注入器 ───────────────────────────

/// 指针信号（滚轮）。`_handlePointerEventImmediately` 对 `PointerSignalEvent`
/// 会**重新 hitTest**（`gestures/binding.dart:454 hitTestInView`）⇒
/// 只要给 `position` + `scrollDelta`，不需要先 Down/Up，也不碰系统光标。
/// ★ `PointerScrollEvent` 的构造器**不透传 `pointer`**（见
/// `.../gestures/events.dart` 里 `PointerScrollEvent` 的 const ctor）
/// ⇒ 这里不能写 `pointer:`，写了就是 `undefined_named_parameter`。
void _injectScroll(Offset at, double dy) {
  WidgetsBinding.instance.handlePointerEvent(PointerScrollEvent(
    position: at,
    scrollDelta: Offset(0, dy),
    kind: PointerDeviceKind.mouse,
  ));
}

Future<bool> _waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 15), String label = ''}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  note('⏱ 等超时: $label（${timeout.inSeconds}s）');
  return false;
}

/// ★ 等帧彻底排空再开测量窗口。
/// 为什么必须做：`addTimingsCallback` 是**异步投递**的，而且
/// `scheduleFrameCallback` 排下的 transient 回调要等下一帧才跑 ⇒
/// 上一个相位（尤其阳性对照那 8 个 200ms 忙等帧）会**漏进**下一个窗口。
/// 第一版实测就踩了这个坑：`切到直播页 首帧 build=200752us` ——
/// 那个 200752 正是阳性对照注入的 200ms，**不是直播页的成本**。
Future<void> _drainFrames() async {
  var last = _all.length;
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (_all.length == last) return;
    last = _all.length;
  }
  note('★ 排空帧等了两轮仍有新帧 ⇒ 有持续动画在跑，后续窗口会含它');
}

// ─────────────────────────── 截图（仪器自检） ───────────────────────────

Future<(String, int)> _shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) return ('(no context)', -1);
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) return ('(not repaint boundary)', -1);
  final img = await ro.toImage(pixelRatio: 1.0);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return ('(no bytes)', -1);
  final path = '$_outDir\\t74p-$name.png';
  File(path).writeAsBytesSync(data.buffer.asUint8List());
  // ★ 唯一颜色数 = 仪器自检：全黑/全白图不能当"页面渲染了"的证据
  final seen = <int>{};
  for (var i = 0; i + 3 < data.lengthInBytes; i += 4 * 7) {
    seen.add(data.getUint32(i));
  }
  return (path, seen.length);
}

/// ★ 极的**生效证据**之二：截图的指纹。
/// 仓里没有 `crypto` 依赖（pubspec 只有 flutter/media_kit/forui/...），
/// 所以用 FNV-1a 64 位自算 —— 它只用来判"两次跑的画面**是否逐字节相同**"，
/// 不需要密码学强度。极 A 与极 B 若画面完全一致 ⇒ 极没生效（空操作）。
String _digestOf(String path) {
  try {
    final b = File(path).readAsBytesSync();
    var h = 0xcbf29ce484222325;
    for (final x in b) {
      h ^= x;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  } catch (e) {
    return '(读取失败 $e)';
  }
}

/// 把极的生效证据打成一整块（**每份产物都必须有**，见本轮教训：
/// "极 B 跑完没报错 ⇒ 认为它生效了" 是本轮踩过的假通过）。
String _poleEvidence() {
  final c = _renderPathCensus();
  final keys = [
    '_VibrancyFill',
    '_FrostedFallback',
    'BackdropFilter',
    'AdaptiveGlass',
    'LightweightLiquidGlass',
    'RepaintBoundary',
  ];
  final parts = [for (final k in keys) '$k=${c[k] ?? 0}'];
  return '极=$_glassPole  ${parts.join('  ')}';
}

// ─────────────────────────── 启动链（镜像 shell.dart:248-546） ───────────────────────────

String _dataDir = '(未解析)';
String _coreResult = '(未启动)';

Future<String> _resolveDataDir() async {
  // ★ 编译期 define 是**兜底**，运行期环境变量优先。
  //   理由：极 P-off 会往数据目录写 `disabled-providers.json`（落盘双写），
  //   若两极共用同一个编译期目录，P-off 会**永久污染** P-on 那一极
  //   ⇒ A/B 就不再是同条件对照。走环境变量 ⇒ 同一个二进制、两个干净目录。
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  final runtime = _envOr('T74_DATA', '');
  final chosen = runtime.isNotEmpty ? runtime : override;
  if (chosen.isNotEmpty) {
    final d = Directory(chosen);
    if (!await d.exists()) await d.create(recursive: true);
    say('数据目录来源 = ${runtime.isNotEmpty ? '运行期 T74_DATA' : '编译期 DATA_DIR_OVERRIDE'}');
    return d.path;
  }
  final appdata = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return '$appdata\\app.sourin.player';
}

Future<T> _timed<T>(String label, Future<T> Function() f) async {
  final a = DateTime.now();
  final r = await f();
  final b = DateTime.now();
  note('启动步 $label = ${b.difference(a).inMilliseconds}ms');
  return r;
}

DateTime? _tFirstFrame;
int _firstMs = -1;

// ─────────────── 极 P：直播页入场的 A/B 注入器（⑤ 第 1 项） ───────────────

/// 极 P-off：**在隔离数据目录里**把全部源禁用。
///
/// 依据（逐字读过）：
///   `rust\sourin_core\src\registry.rs:438-444 live_all()` 只取 `h.enabled` 的源；
///   `commands_provider.rs:40-59 set_enabled_persisted` 既改运行时 registry、
///   又把 id 追加进 `disabled-providers.json` ⇒ 一次调用立刻生效。
/// ⇒ `get_live_channels` 返回空 ⇒ `live_page.dart:867 if (groups.isNotEmpty)`
///   闸门关上 ⇒ `_select()` 不被调用 ⇒ 内嵌播放器**不起播**。
///
/// ★ 本函数**只读/只写隔离数据目录**，生产代码一行不动。
/// ★ 生效证据是**硬断言**：取不到「频道归零」就直接记 fail，
///   这样"极没生效"的跑不会被误当成"P-off 也卡"的结论。
/// ★★ 前置条件断言（防空集假通过 / 铁律 149）：注入**前**必须**非空**。
///   否则插件目录没补齐时 `getLiveChannels()` 本来就返回空，
///   证据①会**空集通过**，看起来像"极生效了"，实际什么都没禁掉。
Future<void> _applyLivePole() async {
  if (_livePole != 'off') {
    say('直播极 T74_LIVE = 「$_livePole」（on = 现状，不注入任何东西）');
    return;
  }
  say('直播极 T74_LIVE = 「off」⇒ 注入：禁用全部源（只动隔离数据目录）');
  try {
    final before = await SourinApi.listProviders();
    final ids = [for (final p in before) p.id];
    final alreadyOff = before.where((p) => !p.enabled).length;
    note('极 P-off 注入前：listProviders 共 ${ids.length} 个源，其中已禁用 $alreadyOff 个');

    // ★★ 前置条件：注入前频道必须**非空**，否则「归零」是空集假通过。
    final pre = await SourinApi.getLiveChannels();
    final preN = pre.fold<int>(0, (a, g) => a + g.channels.length);
    ok('★ 极 P-off 前置条件：注入前频道**非空**（组=${pre.length} 频道=$preN）',
        preN > 0,
        '★ 若为 0 ⇒ 本数据目录的插件/源不完整，注入前后都是 0，'
        '「归零」这条证据**不成立**（空集假通过）⇒ 本跑不得用于归因');

    var changed = 0;
    for (final id in ids) {
      try {
        if (await SourinApi.setProviderEnabled(id, false)) changed++;
      } catch (_) {}
    }
    note('极 P-off：setProviderEnabled(id, false) 返回 true 的有 $changed/${ids.length} 个');

    // ★ 生效证据 ①：get_live_channels 必须从 preN 归零（这才是 _select 的闸门）
    final groups = await SourinApi.getLiveChannels();
    final n = groups.fold<int>(0, (a, g) => a + g.channels.length);
    ok('★ 极 P-off 生效证据①：getLiveChannels() 由 $preN 归零（组=${groups.length} 频道=$n）',
        groups.isEmpty, '★ 若非空 ⇒ 本极**没生效**，本跑不得用于归因');

    // ★ 生效证据 ②：再读一遍 manifest，enabled 必须全 false
    final after = await SourinApi.listProviders();
    final stillOn = [for (final p in after) if (p.enabled) p.id];
    ok('★ 极 P-off 生效证据②：listProviders 里 enabled 全 false（仍启用 ${stillOn.length} 个）',
        stillOn.isEmpty, stillOn.isEmpty ? '' : '仍启用=${stillOn.join(',')}');
  } catch (e) {
    ok('★ 极 P-off 注入', false, '异常=$e ⇒ 本极没生效，本跑不得用于归因');
  }
}

// ─────────── ⑤ 第 2 项：海报「解码尺寸 vs 布局尺寸」实测 ───────────

/// 全渲染树里的 `RenderImage`。
/// `RenderImage extends RenderBox` ⇒ `.size` 是**布局**尺寸；
/// `RenderImage.image` 是 `ui.Image?` ⇒ `.width/.height` 是**解码后**像素。
List<RenderImage> _renderImages() {
  final out = <RenderImage>[];
  void walk(RenderObject ro) {
    if (ro is RenderImage) out.add(ro);
    ro.visitChildren(walk);
  }

  final root = WidgetsBinding.instance.rootElement?.renderObject;
  if (root != null) walk(root);
  return out;
}

/// 把 Lead 的「解码后/布局 ≈ 52 倍」从**推算**升为**实测**。
///
/// 只读两个数：`ui.Image.width×height`（解码后）与 `RenderBox.size`（布局逻辑像素）。
/// ★ 本机 DPR 由引擎直接读，**不猜**（截图字节数曾用来旁证 DPR=1.0）。
void _posterMeasure(String label) {
  final all = _renderImages();
  final live = [for (final r in all) if (r.image != null) r];
  note('$label RenderImage 普查：共 ${all.length} 个，其中已解码 ${live.length} 个');
  if (live.isEmpty) {
    note('$label ★ 没有已解码的 RenderImage ⇒ 本窗口量不到海报，如实报"没量到"');
    return;
  }
  final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  // 按布局面积降序：最大的那个最可能是海报（而不是图标）
  live.sort((a, b) => (b.size.width * b.size.height)
      .compareTo(a.size.width * a.size.height));
  note('$label 设备像素比 DPR = $dpr');
  for (var i = 0; i < live.length && i < 5; i++) {
    final r = live[i];
    final im = r.image!;
    final dw = im.width, dh = im.height;
    final lw = r.size.width, lh = r.size.height;
    final decPx = dw * dh;
    final layPx = (lw * dpr) * (lh * dpr);
    final ratio = layPx <= 0 ? 0.0 : decPx / layPx;
    note('  [$i] 解码 ${dw}x$dh = $decPx px '
        '(${(decPx * 4 / 1024 / 1024).toStringAsFixed(2)}MB @4B/px)  '
        '| 布局 ${lw.toStringAsFixed(1)}x${lh.toStringAsFixed(1)} 逻辑 = '
        '${(lw * dpr).round()}x${(lh * dpr).round()} 物理 = ${layPx.round()} px  '
        '| 解码/布局 = ${ratio.toStringAsFixed(1)}×');
  }
  final r0 = live.first;
  final im0 = r0.image!;
  final lay0 = (r0.size.width * dpr) * (r0.size.height * dpr);
  final ratio0 = lay0 <= 0 ? 0.0 : (im0.width * im0.height) / lay0;
  final layW0 = (r0.size.width * dpr).round();
  final layH0 = (r0.size.height * dpr).round();
  final decW0 = im0.width;
  final wOk = (decW0 - layW0).abs() <= 1;
  final upPct = im0.height > 0 ? (layH0 / im0.height - 1) * 100 : 0.0;
  // ★★ 判据语义已更正（2026-09-29）。旧文案是「若 ≈1 ⇒ 按源分辨率解码不成立」，
  //   它是**为检测 bug 而写**的 ⇒ 修好之后必然**语义翻转**成红（post 跑实测
  //   就是这条唯一 ✗）。现在断言的是「解码宽 == 布局宽（±1px）」= cacheWidth
  //   真的生效。★ 只改判据语义，**不动阈值**（动阈值 = 改判据凑绿）。
  ok('$label ★ 海报实测：解码 ${decW0}x${im0.height} vs 布局 ${layW0}x${layH0} '
      '⇒ 解码宽${wOk ? "==" : "≠"}布局宽（±1px 判据）'
      '  面积比 ${ratio0.toStringAsFixed(2)}×（对照：修前 12.9×/52.5×/173.2× = 按源分辨率解码）'
      '  高度方向 cover 放大 ${upPct.toStringAsFixed(1)}%',
      wOk,
      '★ 判据：解码宽必须 == 布局宽（±1px）⇒ cacheWidth 真的生效。'
      '（高度侧略小于布局高是"只给宽不给高"这条已记录取舍的必然结果，'
      '在 BoxFit.cover 下会被放大回来，故不参与判据、只如实报出）');
}

// ─────────────────────────── 主流程 ───────────────────────────

Future<Never> finish(int code) async {
  // ★ 两个产物文件各自以一行 RESULT 收尾（本仓判据：Lead 只读那一行）
  // ★ 双极对照跑（T74_POLE 非空）时如实标成"极 X"，**不许**冒充 ⑤ 的交付读数。
  // ★ 开关改走环境变量后，命令行**不含**极/页 ⇒ 必须把环境变量逐字写进 RESULT，
  //   否则读数不可复现。
  final cmd = 'flutter build windows --release -t lib/t74_perf_probe.dart '
      '--dart-define=DATA_DIR_OVERRIDE=$_dataDir';
  final envPart = '\$env:T74_GLASS=\'$_glassPole\'; \$env:T74_POLE=\'$_poleTag\'; '
      '\$env:T74_LIVE=\'$_livePole\'; \$env:T74_DATA=\'$_dataDir\'; '
      '\$env:T74_PHASE=\'${_phases.join(',')}\'; '
      '\$env:T74_SIZE=\'$_windowRaw\'; '
      '& .probe\\t74_run_probe.ps1 -WaitSec 300';
  final res = _poleTag.isEmpty
      ? 'RESULT task-74⑤ 真机半 pass=$pass fail=$fail，'
          '启动首帧=${_firstMs}ms，窗口=${_windowRaw}，逐页读数见本文件 | 命令 $cmd | 环境 真机 | 时间 ${_hhmmss()}'
      : 'RESULT task-74⑤ 双极对照·极$_poleTag（玻璃极=$_glassPole，'
          '**归因实验，不是交付读数**）pass=$pass fail=$fail，页=${_phases.join(',')}，'
          '窗口=${_windowRaw}，'
          '启动首帧=${_firstMs}ms，首帧指纹=$_firstShotDigest，'
          '渲染路径 ${_poleEvidence()} | 命令 $cmd + $envPart | '
          '环境 真机(Impeller/OpenGLESSDF) | 时间 ${_hhmmss()}';
  _startupLog.add(res);
  _pagesLog.add(res);
  _cur = _pagesLog;
  debugPrint('[T74P] $res');
  _flush();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(code);
}

String _hhmmss() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

Future<void> main() async {
  final t0 = DateTime.now();
  _origDebugPrint = debugPrint;
  debugPrint = _capturePrint;

  WidgetsFlutterBinding.ensureInitialized();
  _cur = _startupLog;

  say('══════ task-74 ⑤ 整页性能 —— 真机（Windows release）取证 ══════');
  say('可执行文件 = ${Platform.resolvedExecutable}');
  say('工作目录   = ${Directory.current.path}');
  say('Dart 时间戳 = ${t0.toIso8601String()}');

  // ① media_kit：与 shell.dart:276 同款，失败则退回工作目录的 libmpv-2.dll
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll = File('${Directory.current.path}\\libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
      say('media_kit 已用工作目录 libmpv-2.dll 初始化');
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  // ② 窗口：镜像 shell.dart:307-347 的 WindowOptions(size: 1280x800)
  // ★ T74_SIZE 是**窗口面积标定**的开关（形如 `640x400`）。默认值逐字保持
  //   1280x800，这样已有读数一条都不受影响。用途：判定那个 ~5~7ms 的 raster
  //   地板是不是**填充率**（Impeller GLES 每帧把整窗重绘 ⇒ 面积减半则地板减半）
  //   —— 若是，它是引擎税，不是页面内容，不值得继续追。
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      final (w, h) = _windowSize();
      await windowManager.setSize(Size(w.toDouble(), h.toDouble()));
      await windowManager.setTitle('task-74 ⑤ 真机性能取证');
      // ★ 仪器自检：请求的尺寸未必被采纳（屏幕边界/最小尺寸都会夹）
      final actual = await windowManager.getSize();
      final aw = actual.width.toInt();
      final ah = actual.height.toInt();
      say('窗口请求 = ${w}x$h  实际 = ${aw}x$ah'
          '${(aw != w || ah != h) ? '  ★ 被夹住了：面积标定必须用实际值' : ''}');
    } catch (e) {
      note('窗口设置失败（不致命）: $e');
    }
  }

  // ③ Device：★ 必须在 runApp 前（shell.dart:445），否则首帧手机布局再跳 TV 布局
  try {
    await Device.init();
    say('Device.init 完成');
  } catch (e) {
    note('Device.init 失败（沿用默认）: $e');
  }

  // ④ 数据目录 + 偏好 + 核心：镜像 shell.dart:483-527
  String? coreError;
  await _timed('解析数据目录', () async {
    _dataDir = await _resolveDataDir();
  });
  say('数据目录 = $_dataDir');
  await _timed('UiPrefs.load', () => UiPrefs.load(_dataDir));
  _timed('PageTransitionStyleStore.syncFromPrefs', () async {
    PageTransitionStyleStore.syncFromPrefs();
  });
  await _timed('SourinCore.startAsync', () async {
    try {
      final r = await SourinCore.startAsync(_dataDir);
      _coreResult = r.toString();
    } catch (e) {
      coreError = e.toString();
      _coreResult = '★ 失败: $e';
    }
  });
  say('核心启动结果 = $_coreResult');
  if (coreError != null) {
    say('★ 核心错误 = $coreError');
  }
  await _timed('LiquidGlassWidgets.initialize', () => LiquidGlassWidgets.initialize());

  // ⑤ 首帧：★ 在 runApp 之前注册，落在第一帧的 postFrameCallbacks 里
  SchedulerBinding.instance.addPostFrameCallback((_) {
    _tFirstFrame ??= DateTime.now();
  });
  SchedulerBinding.instance.addTimingsCallback(_onTimings);

  // ★ 双极对照的**自变量**注入点：只包在这里，生产文件一行都不动。
  say('玻璃极 T74_GLASS = 「${_glassPole.isEmpty ? '(空=极A 现状)' : _glassPole}」');
  // ★ 极 P（直播页入场 A/B）必须在 runApp **之前**注入：
  //   `get_live_channels` 读的是运行时 registry，早注入 ⇒ 直播页第一次
  //   `loadAll()` 就已经是空列表，入场窗口里**从未**起播。
  await _applyLivePole();
  runApp(_applyGlassPole(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: _dataDir),
  )));

  final got = await _waitUntil(() => _tFirstFrame != null,
      timeout: const Duration(seconds: 40), label: '首帧');
  if (!got || _tFirstFrame == null) {
    ok('启动：采到首帧', false, '40s 内没有首帧 ⇒ 后面全部无读数');
    await finish(1);
  }

  final firstMs = _tFirstFrame!.difference(t0).inMilliseconds;
  _firstMs = firstMs;
  final shell = debugShellKey.currentState;
  ok('启动：shell 已挂载（拿到 debugShellKey.currentState）', shell != null);
  if (shell == null) {
    await finish(1);
  }

  // ── 启动读数 ──
  final firstMark = _mark();
  say('首帧墙钟 = ${firstMs}ms  （main 入口 → 第一帧 postFrameCallback）');
  ok('启动：首帧墙钟已读到（仪器有效）', firstMs > 0, 'firstMs=$firstMs');
  note('首帧时元素数 = ${_elementCount()}');
  {
    final shot = await _shoot('00-first-frame');
    note('首帧截图 ${shot.$1}  采样颜色数=${shot.$2}');
    ok('启动：首帧截图非退化（>20 色）', shot.$2 > 20, '颜色数=${shot.$2}');
  }

  // ── ★ 极的生效证据（每份产物都必须有）──
  // 教训：本轮 Lead 原指定的极 B（改 `LiquidGlassWidgets.wrap`）是**空操作**，
  // 照做会得出「差 <1ms ⇒ 玻璃不是地板」的**错误结论**。所以绝不允许
  // 「跑完没报错 ⇒ 认为极生效了」。这里直接数渲染路径的类名 + 给画面打指纹。
  say('──────── 极的生效证据（不是"没报错"，是数出来的）────────');
  note('渲染路径普查（全树 runtimeType 计数）：${_poleEvidence()}');
  _firstShotDigest = _digestOf('$_outDir\\t74p-00-first-frame.png');
  note('首帧截图指纹 = $_firstShotDigest  （与别的极比：相同 ⇒ 该极是空操作）');
  {
    // 仪器自检：普查必须**数到东西**，全 0 说明遍历没生效（假证据）
    final c = _renderPathCensus();
    final total = c.values.fold<int>(0, (a, b) => a + b);
    ok('极的生效证据：渲染路径普查数到了节点（仪器有效）', total > 0,
        '总命中=$total  ${_poleEvidence()}');
    if (_glassPole == 'b2' || _glassPole == 'b1') {
      final v = c['_VibrancyFill'] ?? 0;
      final f = c['_FrostedFallback'] ?? 0;
      ok('极 $_glassPole 的渲染路径与极 A 不同（_VibrancyFill/$v 或 _FrostedFallback/$f 非零）',
          v > 0 || f > 0,
          '★ 若两个都是 0 ⇒ 本极**没生效**，本跑的读数不得用于归因');
    }
  }

  // 到稳定：等 3s，看树规模是否收敛 + 这段时间的帧读数
  await Future<void>.delayed(const Duration(seconds: 3));
  final settleFrames = _since(firstMark);
  final elemsAfter = _elementCount();
  note('稳定后元素数 = $elemsAfter（首帧时见上）');
  _frames('启动 首帧后 3s 窗口', settleFrames);
  // ★ 仪器自检（⑤ 修法必需项）：先把 epoch 关系钉死，后面所有分箱才可信。
  say(_epochReport());
  _framesByWall('启动 首帧后 3s 窗口', settleFrames, _tFirstFrame ?? t0);
  _frameNumberAudit('启动 首帧后 3s 窗口', settleFrames);

  // ── 阴性对照：空闲窗口，不驱动任何交互 ──
  _cur = _pagesLog;
  say('──────── 对照（先证明仪器会动，再解释读数）────────');
  await _drainFrames(); // 启动动画先排空，空闲窗口才干净
  {
    final m = _mark();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final ts = _since(m);
    _frames('对照·阴性（1.5s 空闲，不注入任何东西）', ts);
    note('★ 阴性对照的用途：窗口内**几乎不产生帧**是正常的（没有动画就没有帧）'
        '⇒ 它只证明"没人在动"，**不能**用来证明"不卡"');
    // ★ Lead 的线索：空闲时仍以 ~13Hz 出帧、且 raster 是大头 ⇒ 怀疑有常驻 Ticker。
    // 判据：`transientCallbackCount > 0` 且持续 ⇒ 确有动画在跑（Ticker 未停）。
    final ticks = <int>[];
    for (var i = 0; i < 15; i++) {
      ticks.add(SchedulerBinding.instance.transientCallbackCount);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final nonZero = ticks.where((t) => t > 0).length;
    note('对照·阴性 期间 transientCallbackCount 采样(15×100ms) = $ticks'
        '（>0 的采样 $nonZero/15）');
    if (nonZero >= 10) {
      note('⇒ **判据成立：有常驻动画在跑**（transient 回调几乎每帧都有）'
          '⇒ 空闲仍在出帧不是"仪器噪声"，是真实的持续重绘');
    } else {
      note('⇒ transient 回调大多为 0 ⇒ 空闲出帧**不是**常驻动画，'
          '更像一次性的收尾帧（不得据此断言"玻璃条有常驻动画"）');
    }
  }

  // ── 阳性对照：transient 回调里注入 200ms 同步忙等 ──
  {
    final m = _mark();
    const rounds = 8;
    for (var i = 0; i < rounds; i++) {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        final end = DateTime.now().add(const Duration(milliseconds: 200));
        // ignore: avoid_while_true
        while (DateTime.now().isBefore(end)) {}
      });
      SchedulerBinding.instance.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final ts = _since(m);
    _frames('对照·阳性（transient 回调注入 200ms 同步忙等 ×$rounds）', ts);
    final builds = [for (final t in ts) t.buildDuration.inMicroseconds];
    final p95 = _pct(builds, 0.95);
    ok('对照·阳性：buildDuration 的 p95 落到 200000us 量级（>=150000us）',
        p95 >= 150000, 'p95=${p95}us  n=${ts.length}');
    if (p95 < 150000) {
      say('★ 阳性对照失败 ⇒ 本探针的帧耗时读数**不可信**，'
          '后面所有"没有 >16.7ms 的帧"都不构成"不卡"的证据');
      await finish(1);
    }
  }

  // ★★ 关键：阳性对照的 8 块忙等**没被同数量的帧消化完**（实测只消化 5 块，
  // 剩 3 块 = 600ms 漏进了「切到直播页」窗口，把直播页首帧污染成 200752us）。
  // 必须在这里排空，否则后面每一页的读数都带着上一相位的残渣。
  await _drainFrames();

  // ── 逐页 ──
  // ★ `_want(phase)` 只在双极对照（T74_PHASE 非空）时收窄；空集时逐字是原行为。
  _cur = _pagesLog;
  note('本跑启用的页 = ${_phases.isEmpty ? '全部（直播/追更/搜索/设置）' : _phases.join(' + ')}'
      '${_poleTag.isEmpty ? '' : '   极 = $_poleTag'}');
  if (_want('live')) {
    await _phaseSwitch(shell, AppTab.live, '直播页');
    await _phaseLive();
  }
  if (_want('follow')) {
    await _phaseSwitch(shell, AppTab.follow, '追更页');
    await _phaseFollow();
  }
  if (_want('search')) {
    await _phaseSwitch(shell, AppTab.search, '搜索页');
    await _phaseSearch();
  }
  if (_want('settings')) {
    await _phaseSwitch(shell, AppTab.settings, '设置页');
    await _phaseSettings();
  }

  // ── 收尾 ──
  _cur = _pagesLog;
  say('──────── 应用自己打出来的关键行（生产路径证据）────────');
  final keys = ['[SHELL]', '[SETTINGS]', '[FOLLOW]', '[LIVE]', '[SEARCH]'];
  var shown = 0;
  for (final line in _appPrints) {
    if (keys.any(line.contains)) {
      say('  app| $line');
      shown++;
      if (shown >= 80) break;
    }
  }
  note('app 打印总行数 = ${_appPrints.length}（其中含关键前缀的已列上面 $shown 行）');

  final shot = await _shoot('99-final');
  note('收尾截图 ${shot.$1}  采样颜色数=${shot.$2}');

  say('══════ 结束 pass=$pass fail=$fail ══════');
  await finish(fail == 0 ? 0 : 1);
}

// ─────────────────────────── 各页相位 ───────────────────────────

Future<void> _phaseSwitch(dynamic shell, AppTab t, String name) async {
  _cur = _pagesLog;
  await _drainFrames(); // ★ 上一相位的残帧不许漏进本页窗口
  say('──────── 切到 $name（首次建页；保活页只建一次）────────');
  // ★ 每一页的读数都自带极的标识 + 渲染路径普查 ⇒ 单看一页也能判"本极是否生效"
  note('本页极=$_glassPole  ${_poleEvidence()}');
  final m = _mark();
  final w0 = DateTime.now();
  // `_ShellPageState` 是私有类型 ⇒ 只能经 `dynamic` 调它的公开探针钩子
  shell.debugSwitchTo(t);
  // ★ 把 1.2s 观察窗切成 3×400ms 分段：总窗口逐字不变（已有读数仍可比），
  //   但能回答"入场突发集中在哪一段" —— 直播页 p50=22852us 是全程如此，
  //   还是只有建页那一瞬？（Lead 的三条交叉证据指向"入场突发"，这里给读数）
  final segs = <List<FrameTiming>>[];
  for (var i = 0; i < 3; i++) {
    final ms = _mark();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    segs.add(_since(ms));
  }
  final ts = _since(m);
  final w1 = DateTime.now();
  note('切页墙钟（含 1.2s 观察窗）= ${w1.difference(w0).inMilliseconds}ms');
  _firstFrame('切到$name', ts);
  for (var i = 0; i < segs.length; i++) {
    final lo = i * 400;
    _frames('切到$name 分段 ${lo}~${lo + 400}ms', segs[i]);
  }
  _frames('切到$name 1.2s 窗口', ts);
  // ★★ 仪器修法：上面那三行「分段」读数**不可信**（见 _framesByWall 顶部长注释：
  //    同一 app.so 两跑之间分段会互相搬家 ⇒ 那是投递抖动不是页面属性）。
  //    下面这组按真实墙钟重新分箱，并给 frameNumber 连续性 + 逐帧时间线。
  note('★ 上面三行「分段」是**回调投递位置**，不是帧发生位置 ⇒ 归属不可信；'
      '以下按真实墙钟重新分箱（这才是可归因的读数）');
  _framesByWall('切到$name', ts, w0);
  _frameNumberAudit('切到$name', ts);
  _frameTimeline('切到$name', ts, w0, cap: 30);
  note('切到$name 后 ${_imageCacheLine()}');
  ok('切到$name：窗口内产生了帧（仪器有效）', ts.isNotEmpty, 'n=${ts.length}');
}

Future<void> _phaseLive() async {
  final st = _stateOf(LivePage) as LivePageState?;
  ok('直播页：拿到 LivePageState', st != null);
  if (st == null) return;
  // 切页本身会经 `widget.visible` 触发加载；这里只等它落定
  // ★ 这 2s = Lead 要的「入场突发之后」：_phaseSwitch 的分段读数覆盖入场那
  //   1.2s（0~400 / 400~800 / 800~1200），这里的窗口覆盖**稳态**。
  //   两者相减才能回答"23ms 是入场突发还是全程如此"。
  note('直播页 入场后（切页起 2s）${_imageCacheLine()}');
  await Future<void>.delayed(const Duration(seconds: 2));
  final m = _mark();
  await st.loadAll();
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  final ts = _since(m);
  _frames('直播页 loadAll() 稳态窗口', ts);
  note('★ 局限：本页**没有** `@visibleForTesting` 钩子 ⇒ 无法断言频道条数，'
      '只能报"调用了 loadAll 并观察 1.2s 窗口"');
  final shot = await _shoot('10-live');
  note('直播页截图 ${shot.$1}  采样颜色数=${shot.$2}');
  note('直播页 稳态后 ${_imageCacheLine()}');
  ok('直播页：截图非退化（>20 色）', shot.$2 > 20, '颜色数=${shot.$2}');
}

Future<void> _phaseFollow() async {
  final st = _stateOf(FollowPage) as FollowPageState?;
  ok('追更页：拿到 FollowPageState', st != null);
  if (st == null) return;
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final real = st.debugContinueList.length;
  note('追更页：真实数据加载后 continue 条数 = $real（数据目录 $_dataDir）');

  final rows = <Progress>[
    for (var i = 0; i < 20; i++)
      Progress(
        key: 'probe:$i',
        provider: 'probe',
        nativeId: '$i',
        title: '真机性能样本 第$i部',
        episodeTitle: '第 ${i + 1} 集',
        position: 600 + i * 10,
        duration: 2400,
        updatedAt: DateTime.now().millisecondsSinceEpoch - i * 1000,
      ),
  ];
  final m = _mark();
  st.debugSetContinueList(rows);
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  final ts = _since(m);
  note('追更页：注入 20 条后 continue 条数 = ${st.debugContinueList.length}');
  ok('追更页：注入生效（条数 = 20）', st.debugContinueList.length == 20,
      '实际=${st.debugContinueList.length}');
  _firstFrame('追更页 注入 20 条', ts);
  _frames('追更页 注入 20 条', ts);
  final shot = await _shoot('20-follow');
  note('追更页截图 ${shot.$1}  采样颜色数=${shot.$2}');

  // ★★ 第一版实测教训：`debugSetContinueList` 只改数据，**不改当前 tab**。
  // 默认 tab 是「追更」(following)，注入的 20 条「继续观看」根本没被渲染 ⇒
  // 量到 `可滚容器数 = 0`，那不是"追更页不能滚"，是**我量错了页签**。
  // `showTab` 是公开写入口（`follow_page.dart:306 bool showTab(String key)`）。
  final switched = st.showTab('continue');
  note('追更页：showTab("continue") = $switched');
  await Future<void>.delayed(const Duration(milliseconds: 800));

  // 滚动：找追更页下可滚的 ScrollableState
  final el = _findElement((w) => w.runtimeType == FollowPage);
  if (el == null) {
    ok('追更页：找到页面 Element 以定位滚动容器', false);
    return;
  }
  final scs = _scrollablesUnder(el)
      .where((s) => s.position.maxScrollExtent > 1)
      .toList();
  note('追更页下可滚容器数 = ${scs.length}'
      '（maxScrollExtent: ${scs.map((s) => s.position.maxScrollExtent.toStringAsFixed(0)).join(", ")}）');
  if (scs.isEmpty) {
    ok('追更页：存在可滚动容器', false, '⇒ 滚动读数无从谈起');
    return;
  }
  final sc = scs.first;
  final rb = sc.context.findRenderObject();
  if (rb is! RenderBox) {
    ok('追更页：滚动容器有 RenderBox', false);
    return;
  }
  final at = rb.localToGlobal(rb.size.center(Offset.zero));
  final before = sc.position.pixels;
  final m2 = _mark();
  for (var i = 0; i < 12; i++) {
    _injectScroll(at, 120);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final after = sc.position.pixels;
  final ts2 = _since(m2);
  note('追更页滚动：pixels $before → $after（Δ=${(after - before).toStringAsFixed(1)}）');
  ok('追更页滚动：滚动**真的发生了**（pixels 变化 > 100）', (after - before).abs() > 100,
      'Δ=${(after - before).toStringAsFixed(1)}');
  _frames('追更页 滚 12×120px', ts2);
  // ★ Lead 的线索：追更页是**海报页**（截图 19912 色 ⇒ 图真的画出来了），
  //   而 `lib/` 里 `cacheWidth`/`ResizeImage` 命中 0 ⇒ 怀疑按源分辨率解码。
  //   这条只读 imageCache 的公开计数：若驻留字节随海报张数线性膨胀，
  //   线索成立；若只有几 MB，则线索被证伪。
  note('追更页 滚后 ${_imageCacheLine()}');
  // ★ ⑤ 第 2 项：把 Lead 的「解码后/布局 ≈ 52 倍」从**推算**升为**实测**。
  //   这一页是海报页（截图 19912 色 ⇒ 图真的画出来了）⇒ 就在这量。
  _posterMeasure('追更页');
}

Future<void> _phaseSearch() async {
  final st = _stateOf(SearchPage) as SearchPageState?;
  ok('搜索页：拿到 SearchPageState', st != null);
  if (st == null) return;
  await Future<void>.delayed(const Duration(milliseconds: 600));
  st.debugSetProviderCount(30);
  st.debugBeginSearch('真机性能样本');
  await Future<void>.delayed(const Duration(milliseconds: 400));

  final perHit = <int>[];
  final m = _mark();
  for (var i = 0; i < 20; i++) {
    final mh = _mark();
    st.debugFeedHit(SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: 'probe$i',
      providerName: '样本源$i',
      items: [
        for (var j = 0; j < 5; j++)
          MediaItem(
            id: 'probe$i:$j',
            title: '真机性能样本 第$i部 第$j集',
            provider: 'probe$i',
          ),
      ],
    ));
    // ★★ 第一版实测教训：固定 `Future.delayed(50ms)` 后立刻读 `_since(mh)`，
    // 19/20 次读到**空样本 ⇒ 记 0**。`setState` 只排帧，帧不一定在 50ms 内
    // 被 `addTimingsCallback` 投递出来 ⇒ 读到 0 **不是"这帧很便宜"**，是没采到。
    // 修法：等到**该次 hit 真的产生了一帧**再读（上限 400ms），
    // 采不到就如实记 -1（"未采到"），与"0us"区分开。
    var waited = 0;
    while (_all.length <= mh && waited < 400) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited += 10;
    }
    final f = _since(mh);
    perHit.add(f.isEmpty ? -1 : f.first.buildDuration.inMicroseconds);
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final ts = _since(m);
  final got = perHit.where((v) => v >= 0).toList();
  note('搜索页：20 次 hit（每次 5 条）逐次首帧 build 微秒 = $perHit'
      '（-1 = 该次 400ms 内未采到帧，**不是** 0us）');
  note('搜索页：有效样本 ${got.length}/20'
      '  p50=${_pct(got, 0.50)}  p95=${_pct(got, 0.95)}  max=${_maxOf(got)}');
  note('搜索页：首/末有效对比 = ${got.isEmpty ? "-" : got.first} → '
      '${got.isEmpty ? "-" : got.last}'
      '（与合成半 PA「重建面 199 → 428」同口径：看有没有随命中数增长）');
  _frames('搜索页 20 hit', ts);
  final shot = await _shoot('30-search');
  note('搜索页截图 ${shot.$1}  采样颜色数=${shot.$2}');
  ok('搜索页：截图非退化（>20 色）', shot.$2 > 20, '颜色数=${shot.$2}');
}

Future<void> _phaseSettings() async {
  final st = _stateOf(SettingsPage) as SettingsPageState?;
  ok('设置页：拿到 SettingsPageState', st != null);
  if (st == null) return;

  final el = _findElement((w) => w.runtimeType == SettingsPage);
  if (el == null) {
    ok('设置页：找到页面 Element', false);
    return;
  }
  // 等 ListView 出来（`_loading` 期间整个树被 Center(进度圈) 替换）
  final ready = await _waitUntil(
      () => _scrollablesUnder(el).any((s) => s.position.maxScrollExtent > 1),
      timeout: const Duration(seconds: 25), label: '设置页可滚容器出现');
  final shot0 = await _shoot('40-settings');
  note('设置页截图 ${shot0.$1}  采样颜色数=${shot0.$2}');
  ok('设置页：截图非退化（>20 色 ⇒ 不是 ErrorWidget 空白页）', shot0.$2 > 20,
      '颜色数=${shot0.$2}');

  final scs = _scrollablesUnder(el)
      .where((s) => s.position.maxScrollExtent > 1)
      .toList();
  note('设置页可滚容器数 = ${scs.length}  ready=$ready'
      '（maxScrollExtent: ${scs.map((s) => s.position.maxScrollExtent.toStringAsFixed(0)).join(", ")}）');
  ok('设置页：找到可滚动容器（合成侧做不到的那一条）', scs.isNotEmpty);
  if (scs.isEmpty) {
    note('★ 合成半 PB 的结论是「挂不上（ErrorWidget=1）⇒ 只能真机量」；'
        '这里如果也拿不到可滚容器，就必须如实报告"真机也没量到"');
    return;
  }

  // 取 maxScrollExtent 最大的那个（主设置列表）
  scs.sort((a, b) => b.position.maxScrollExtent.compareTo(a.position.maxScrollExtent));
  final sc = scs.first;
  final rb = sc.context.findRenderObject();
  if (rb is! RenderBox) {
    ok('设置页：滚动容器有 RenderBox', false);
    return;
  }
  final at = rb.localToGlobal(rb.size.center(Offset.zero));
  note('设置页滚动注入点（全局坐标）= ${at.dx.toStringAsFixed(1)},${at.dy.toStringAsFixed(1)}'
      '  视口=${rb.size.width.toStringAsFixed(0)}x${rb.size.height.toStringAsFixed(0)}');

  final before = sc.position.pixels;
  final m = _mark();
  for (var i = 0; i < 20; i++) {
    _injectScroll(at, 200);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final after = sc.position.pixels;
  final ts = _since(m);
  note('设置页滚动：pixels $before → $after（Δ=${(after - before).toStringAsFixed(1)}）');
  ok('设置页滚动：滚动**真的发生了**（pixels 变化 > 200）', (after - before).abs() > 200,
      'Δ=${(after - before).toStringAsFixed(1)}');
  _frames('设置页 滚 20×200px', ts);
  final shot1 = await _shoot('41-settings-scrolled');
  note('设置页滚动后截图 ${shot1.$1}  采样颜色数=${shot1.$2}');

  // 反向滚回来（证明两个方向都能量）
  final m2 = _mark();
  for (var i = 0; i < 10; i++) {
    _injectScroll(at, -200);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  note('设置页回滚：pixels $after → ${sc.position.pixels}');
  _frames('设置页 回滚 10×-200px', _since(m2));

  // ★★ 真机复现 `settings_page.dart:203` 注释里记的那个**已复现真 bug**：
  // `build()` 里 `if (_loading) return const Center(child: CircularProgressIndicator());`
  // **整个替换**掉 ListView ⇒ 滚动位置归零 ⇒ 用户看到的正是「设置页往下滑，
  // 自动往上滚」。合成侧的证据在 `.probe/probe_tests/zz_probe_t3_scroll_guard_test.dart`；
  // 这里用**真机 + 真 FFI** 再量一次，判据是 pixels 是否被打回 0。
  {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // 先滚下去一段，制造可观察的偏移
    for (var i = 0; i < 3; i++) {
      _injectScroll(at, 200);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final p0 = sc.position.pixels;
    final m3 = _mark();
    final st2 = _stateOf(SettingsPage) as SettingsPageState?;
    if (st2 == null) {
      note('★ 设置页：二次拿不到 SettingsPageState ⇒ 本项跳过');
    } else {
      await st2.loadAll(); // 与 initState 里那条路径同一个方法
      await Future<void>.delayed(const Duration(milliseconds: 900));
      // 重新取一次 ScrollableState：若 ListView 被整个替换过，旧实例已失效
      final el2 = _findElement((w) => w.runtimeType == SettingsPage);
      final scs2 = el2 == null
          ? <ScrollableState>[]
          : _scrollablesUnder(el2)
              .where((s) => s.position.maxScrollExtent > 1)
              .toList();
      final p1 = scs2.isEmpty ? double.nan : scs2.first.position.pixels;
      note('设置页 重入 loadAll()：滚动位置 $p0 → '
          '${p1.isNaN ? "（ListView 已消失，无可滚容器）" : p1.toStringAsFixed(1)}'
          '  可滚容器数=${scs2.length}');
      if (p1.isNaN) {
        note('⇒ **真机复现：loadAll() 期间 ListView 整个消失**（`_loading` 分支），'
            '滚动位置随之丢失 ⇒ 这就是「设置页自动往上滚」的机制');
      } else if (p0 > 100 && p1 < 1) {
        note('⇒ **真机复现：loadAll() 后滚动位置被打回顶部**（$p0 → $p1）'
            '⇒ 与 `settings_page.dart:203` 注释记录的现象一致');
      } else if ((p0 - p1).abs() > 100) {
        note('⇒ 真机复现：loadAll() 后滚动位置**变了 ${(p0 - p1).abs().toStringAsFixed(0)}px**'
            '（不是打回 0，但确实跳动）');
      } else {
        note('⇒ 本次未复现（位置 ${p0.toStringAsFixed(1)} → ${p1.toStringAsFixed(1)}）'
            '⇒ 不得据此说"这个 bug 不存在"，只能说"这条路径下没触发"');
      }
      _frames('设置页 重入 loadAll()', _since(m3));
    }
  }
}
