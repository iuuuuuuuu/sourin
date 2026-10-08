// ═══════════════════════════════════════════════════════════════════════
//  弹幕渲染层（task-13 ⑦ 层(b)：本地弹幕）
// ═══════════════════════════════════════════════════════════════════════
//
// #  职责边界（别把两层搞混）
//
// ```text
// lib/core/danmaku.dart                纯 Dart：HTTP + 解析 + 轨道分配（可单测）
// lib/ui/widgets/danmaku_overlay.dart  ← 本文件：只负责照着排版结果画出来
// ```
// 本文件不做任何时间/轨道计算 —— 每条弹幕在第几轨道、什么时候进出，
// 全部来自 DanmakuLayout。这样不重叠这个验收点可以在没有渲染器的情况下
// 用纯计算证明（见 test/task13_danmaku_test.dart 的 900 帧逐帧相交检测），
// 渲染层只保证画出来的就是排版算出来的。
//
// # ★ 为什么必须自驱动帧循环（不能只靠 position 流）
//
// _onPositionTick 的触发源是 mpv 的 time-pos，实测每秒只有几次，
// 而且生产代码里 setState 还被 secChanged 守卫（见 player_page.dart:2083）。
// 拿它当渲染时钟 ⇒ 滚动弹幕会以 4fps 一跳一跳地走，那是动画坏了，
// 不是弹幕。
//
// 所以：位置流只用来校准，帧循环用 Ticker 自己走：
// ```text
// t = 锚点位置 + (本地经过的时间) × 倍速
// 位置流每来一次 ⇒ 与本地预测比一下
//   |差| ≤ 0.35s  ⇒ 不动（保持平滑，避免每秒一次的小跳变）
//   |差| > 0.35s  ⇒ 重新锚定（seek / 起播 / 暂停恢复 / 累积漂移）
// ```
// 于是误差有界（≤0.35s，对弹幕来说看不出来），而画面始终是平滑的。
//
// # 几何：必须自己算 contain 矩形
//
// Video widget 自己铺满整屏、内部按 BoxFit.contain 居中
// （实测见 player_page.dart:6875-6883）。所以弹幕层必须用同一套几何，
// 否则画面有黑边时弹幕会画到黑边上（那是错的）。
// danmakuContainRect 就是那段算法，与描边层（player_page.dart:6939-6947）
// 逐像素一致 —— 两处都改时必须一起改。
//
// # 禁止 `package:flutter/material.dart`
//
// 项目用拆包后的 material_ui（见 test/material_split_test.dart）。
// Ticker 不在 material_ui 的导出面（scheduler 不被转出），
// 所以这里显式 import package:flutter/scheduler.dart —— 实测必需。

import 'dart:math' as math;

// ★ 只为了 `Ticker`（material_ui 不转出 scheduler，实测）
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/danmaku.dart';
import '../tokens.dart';

/// 弹幕基准字号（px，逻辑像素）
///
/// 乘上用户设置的 `fontScale` 才是真实字号。
/// 取 24 的依据：1280x800 窗口下与常见网页播放器的字号观感接近，
/// 且 24 × 1.35 = 32.4px 行高 ⇒ 800 高能排 24 条轨道，够用。
const double kDanmakuBaseFontSize = 24;

/// 行高系数（与 `DanmakuTrackAllocator` 的缺省值一致，别在两处写死不同的数）
const double kDanmakuLineHeightFactor = 1.35;

/// 同轨道两条滚动弹幕的最小空隙（px）
const double kDanmakuGap = 24;

/// 固定弹幕（顶部/底部）的停留时长（秒）
const double kDanmakuFixedSeconds = 4.0;

/// 文本测量缓存的容量上限（超过就整体清空重建）
const int kDanmakuMaxTextPainters = 3000;

/// 探针帧记录上限（超过就停止追加，只置一个截断标志）
const int kDanmakuMaxProbeFrames = 6000;

/// `BoxFit.contain` 的矩形；[aspect] 拿不到时返回 null（= 不画）
///
/// ⚠️ 与描边层（player_page.dart 里那段 `LayoutBuilder`）**必须一致** ——
///    两处算的是同一个画面区域，一处改了另一处也要改。
Rect? danmakuContainRect(Size box, double? aspect) {
  if (aspect == null || aspect <= 0 || box.width <= 0 || box.height <= 0) {
    return null;
  }
  var w = box.width;
  var h = w / aspect;
  if (h > box.height) {
    h = box.height;
    w = h * aspect;
  }
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

// -----------------------------------------------------------------------
//  探针读数（真进程实测用；生产路径里只是几个自增，没有分支依赖它们）
// -----------------------------------------------------------------------

/// 一帧的渲染读数
class DanmakuFrameSample {
  const DanmakuFrameSample({
    required this.time,
    required this.trackedLeft,
    required this.visible,
    required this.overlapPairs,
  });

  /// 这一帧用的时间（秒）
  final double time;

  /// 被跟踪的那条滚动弹幕的左边界；不可见时为 null
  final double? trackedLeft;

  /// 这一帧画了几条
  final int visible;

  /// 这一帧检测到的矩形相交对数（**必须恒为 0**）
  final int overlapPairs;

  @override
  String toString() => 't=${time.toStringAsFixed(3)} '
      'left=${trackedLeft == null ? "-" : trackedLeft!.toStringAsFixed(1)} '
      'visible=$visible overlap=$overlapPairs';
}

/// 最近一帧的汇总读数
class DanmakuRenderStats {
  const DanmakuRenderStats({
    required this.laneCount,
    required this.placed,
    required this.dropped,
    required this.visible,
    required this.time,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.fontSize,
    required this.speedPxPerSecond,
  });

  final int laneCount;
  final int placed;
  final int dropped;
  final int visible;
  final double time;
  final double canvasWidth;
  final double canvasHeight;
  final double fontSize;
  final double speedPxPerSecond;

  @override
  String toString() => '轨道=$laneCount 排版=$placed 丢弃=$dropped '
      '可见=$visible t=${time.toStringAsFixed(2)} '
      '画面=${canvasWidth.toStringAsFixed(0)}x${canvasHeight.toStringAsFixed(0)} '
      '字号=${fontSize.toStringAsFixed(1)} '
      '速度=${speedPxPerSecond.toStringAsFixed(1)}px/s';
}

/// 最近一帧的汇总（未渲染过时为 null）
DanmakuRenderStats? debugDanmakuLastStats;

/// 真正执行了 `paint()` 的帧数（**证明帧循环真的在跑**）
int debugDanmakuPaintedFrames = 0;

/// 出现过矩形相交的帧数（**必须恒为 0**）
int debugDanmakuOverlapFrames = 0;

/// 单帧最多检测到几对相交
int debugDanmakuMaxOverlapPairs = 0;

/// 逐帧采样（有上限）
final List<DanmakuFrameSample> debugDanmakuFrames = <DanmakuFrameSample>[];

/// 采样是否因为超过上限而停止追加
bool debugDanmakuFramesTruncated = false;

/// 清零探针读数（每次实测前调一次，否则会读到上一轮的累积值）
void debugDanmakuResetProbeStats() {
  debugDanmakuLastStats = null;
  debugDanmakuPaintedFrames = 0;
  debugDanmakuOverlapFrames = 0;
  debugDanmakuMaxOverlapPairs = 0;
  debugDanmakuFrames.clear();
  debugDanmakuFramesTruncated = false;
}

// -----------------------------------------------------------------------
//  可见区间索引（避免每帧全表扫描）
// -----------------------------------------------------------------------

/// 按 `enterAt` 排序的可见区间索引
///
/// # 为什么需要它
///
/// `DanmakuLayout.at(t)` 是 O(n) 全表扫描。真实弹幕库单集 800~10000 条，
/// 60fps 下就是 60 万次比较/秒 —— 能跑，但没必要。
///
/// # 正确性依据
///
/// 每条弹幕的可见区间长度有上界（滚动 = `(画宽+文本宽)/速度`，
/// 固定 = `fixedSeconds`）⇒ `enterAt < t - maxSpan` 的**必然**不可见。
/// 于是只需要在 `[t - maxSpan, t]` 这个窗口里筛 —— 结果与全表扫描**完全一致**，
/// 不是近似。
class _LayoutIndex {
  _LayoutIndex(List<DanmakuPlacement> all)
      : sorted = List<DanmakuPlacement>.of(all)
          ..sort((a, b) => a.enterAt.compareTo(b.enterAt)) {
    var span = 0.0;
    for (final p in sorted) {
      final s = p.exitAt - p.enterAt;
      if (s > span) span = s;
    }
    maxSpan = span;
  }

  final List<DanmakuPlacement> sorted;

  /// 可见区间长度的上界（秒）
  late final double maxSpan;

  bool get isEmpty => sorted.isEmpty;

  int get length => sorted.length;

  /// 第一个 `enterAt > t` 的下标
  int _upperBound(double t) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid].enterAt > t) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// 第一个 `enterAt >= t` 的下标
  int _lowerBound(double t) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid].enterAt >= t) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// 某个时刻真正可见的那些（与 `layout.at(t)` 逐条等价）
  List<DanmakuPlacement> visibleAt(double t) {
    final hi = _upperBound(t);
    final lo = _lowerBound(t - maxSpan);
    final out = <DanmakuPlacement>[];
    for (var i = lo; i < hi; i++) {
      final p = sorted[i];
      if (p.visibleAt(t)) out.add(p);
    }
    return out;
  }
}

// -----------------------------------------------------------------------
//  文本测量缓存
// -----------------------------------------------------------------------

class _DanmakuText {
  _DanmakuText(this.fill, this.stroke);

  final TextPainter fill;
  final TextPainter stroke;

  double get width => fill.width;

  void dispose() {
    fill.dispose();
    stroke.dispose();
  }
}

/// 文本 → 已排版的 [TextPainter]（含描边层）
///
/// # 为什么必须缓存
///
/// `TextPainter.layout()` 是弹幕渲染里最贵的一步（要跑一遍文字排版）。
/// 60fps × 几十条可见弹幕 = 每秒上千次排版，不缓存会明显掉帧。
/// 弹幕文本重复率高（"哈哈" / "666" / "前排"），缓存命中率很好。
class _TextCache {
  final Map<String, _DanmakuText> _map = <String, _DanmakuText>{};

  int get length => _map.length;

  void clear() {
    for (final t in _map.values) {
      t.dispose();
    }
    _map.clear();
  }

  _DanmakuText get({
    required String text,
    required double fontSize,
    required Color color,
    required double opacity,
  }) {
    final a = (opacity * 100).round() / 100;
    final key = '$text\u0001${fontSize.toStringAsFixed(2)}'
        '\u0001${color.toARGB32()}\u0001$a';
    final hit = _map[key];
    if (hit != null) return hit;

    if (_map.length >= kDanmakuMaxTextPainters) clear();

    final strokeW = math.max(2.0, fontSize * 0.12);
    final fill = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withValues(alpha: a),
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeW
            ..strokeJoin = StrokeJoin.round
            ..color = Colors.black.withValues(alpha: a * 0.85),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final made = _DanmakuText(fill, stroke);
    _map[key] = made;
    return made;
  }
}
// -----------------------------------------------------------------------
//  渲染 widget
// -----------------------------------------------------------------------

/// 弹幕层
///
/// 用法（在播放页的视频 Stack 里，视频画面之后、描边层之前）：
/// ```dart
/// Positioned.fill(
///   child: IgnorePointer(
///     child: DanmakuOverlay(
///       aspect: _displayAspect,
///       comments: _danmakuComments,
///       position: _position,
///       playing: _playing,
///       rate: _rate,
///       enabled: _danmaku,
///       fontScale: DanmakuConfig.fontScale,
///       opacity: DanmakuConfig.opacity,
///       speed: DanmakuConfig.speed,
///       area: DanmakuConfig.area,
///     ),
///   ),
/// )
/// ```
///
/// ⚠️ 外层**必须**是 `IgnorePointer` —— 弹幕层不能吃掉播放页的手势
///    （单击显示控制条 / 双击快进退 / 长按倍速都靠那些手势）。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.aspect,
    required this.comments,
    required this.position,
    required this.playing,
    this.rate = 1.0,
    this.enabled = true,
    this.fontScale = DanmakuConfig.defaultFontScale,
    this.opacity = DanmakuConfig.defaultOpacity,
    this.speed = DanmakuConfig.defaultSpeed,
    this.area = DanmakuConfig.defaultArea,
    this.badge,
  });

  /// 视频真实宽高比（`_displayAspect`）；null = 拿不到 ⇒ 不画
  final double? aspect;

  /// 已按时间排好序的弹幕
  final List<DanmakuComment> comments;

  /// 播放器位置（**只用来校准**，见文件头）
  final Duration position;

  final bool playing;

  /// 播放倍速（本地时钟按它推进；位置流会持续纠偏）
  final double rate;

  /// 总开关（false 时既不排版也不画）
  final bool enabled;

  /// 字号缩放（`DanmakuConfig.fontScale`）
  final double fontScale;

  /// 不透明度（`DanmakuConfig.opacity`）
  final double opacity;

  /// 一条弹幕从右边缘走到左边缘的秒数（越大越慢）
  final double speed;

  /// 纵向可占用比例（`DanmakuConfig.area`）
  final double area;

  /// 画面左上角的角标文字（用来**如实标注**"这批弹幕是哪来的"）
  final String? badge;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// 本地时钟（**一直在跑**，暂停时只是不用它推进）
  final Stopwatch _sw = Stopwatch()..start();

  /// 只触发重绘、不触发重建（弹幕每秒 60 帧，走 setState 会重建整棵子树）
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  final _TextCache _cache = _TextCache();

  /// 本地时钟的锚点：`_anchorPos` 秒对应 `_anchorWall` 这个本地时刻
  double _anchorPos = 0;
  double _anchorWall = 0;

  /// 当前用于绘制的时刻（秒）
  double _t = 0;

  DanmakuLayout? _layout;
  _LayoutIndex? _index;

  /// 排版缓存键（任一变化都要重排）
  List<Object?>? _layoutKey;

  /// 被跟踪的那条滚动弹幕在 `_index.sorted` 里的下标（探针用，-1 = 没有）
  int _tracked = -1;

  bool _tickerActive = false;

  @override
  void initState() {
    super.initState();
    _anchorPos = widget.position.inMicroseconds / 1e6;
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _t = _anchorPos;
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);

    final reported = widget.position.inMicroseconds / 1e6;
    final oldReported = old.position.inMicroseconds / 1e6;
    final predicted = _computeT();

    /*
     * ★ 校准规则（文件头有完整推导）
     *
     * 暂停/恢复、倍速变化 ⇒ **立刻**重新锚定（这两件事本地时钟推不出来）；
     * 位置流报来的新值只在**偏差超过阈值**时才采纳 ——
     * 否则每秒都会有一次肉眼可见的小跳变。
     */
    final rateChanged = widget.rate != old.rate;
    final playChanged = widget.playing != old.playing;
    if (playChanged || rateChanged || (reported - predicted).abs() > 0.35) {
      _anchorPos = reported;
      _anchorWall = _sw.elapsedMicroseconds / 1e6;
    } else if (reported != oldReported) {
      // 小偏差：不动锚点（保持平滑），但把当前时刻更新到预测值
      _t = predicted;
    }

    if (!widget.playing) _t = _anchorPos;
  }

  @override
  void dispose() {
    if (_tickerActive) _ticker.stop();
    _ticker.dispose();
    _cache.clear();
    _repaint.dispose();
    super.dispose();
  }

  double _computeT() {
    if (!widget.playing) return _anchorPos;
    final wall = _sw.elapsedMicroseconds / 1e6;
    return _anchorPos + (wall - _anchorWall) * widget.rate;
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    _t = _computeT();
    // ★ 只标脏绘制，不 setState（整页重建的代价在播放页里非常贵）
    _repaint.value++;
  }

  void _syncTicker() {
    final idx = _index;
    final want = widget.enabled &&
        widget.playing &&
        idx != null &&
        idx.length > 0;
    if (want == _tickerActive) return;
    _tickerActive = want;
    if (want) {
      _ticker.start();
    } else {
      _ticker.stop();
      _t = _computeT();
    }
  }

  /// 排版时用的文本测量（**必须与绘制时同一套度量**）
  ///
  /// 测量用白色 + 全不透明：文本宽度与颜色/透明度无关，
  /// 但把它固定下来能让缓存键与绘制时的缓存键分开（少一次哈希冲突的可能）。
  double _measure(String text, double fontSize) {
    return _cache
        .get(
          text: text,
          fontSize: fontSize,
          color: const Color(0xFFFFFFFF),
          opacity: 1,
        )
        .width;
  }

  void _ensureLayout(Size canvas) {
    final fontSize = kDanmakuBaseFontSize * widget.fontScale;
    // 秒/屏 → px/s（画宽越宽，同样"几秒走完"就越快）
    final pxPerSecond = canvas.width / math.max(widget.speed, 0.1);
    final key = <Object?>[
      canvas.width,
      canvas.height,
      fontSize,
      pxPerSecond,
      widget.area,
      widget.comments.length,
      identityHashCode(widget.comments),
    ];
    final old = _layoutKey;
    if (old != null && _sameKey(old, key)) return;
    _layoutKey = key;
    final l = DanmakuTrackAllocator.layout(
      comments: widget.comments,
      canvasWidth: canvas.width,
      canvasHeight: canvas.height,
      fontSize: fontSize,
      lineHeight: fontSize * kDanmakuLineHeightFactor,
      speed: pxPerSecond,
      area: widget.area,
      fixedSeconds: kDanmakuFixedSeconds,
      gap: kDanmakuGap,
      measure: _measure,
    );
    _layout = l;
    _index = _LayoutIndex(l.placements);
    _cache.clear();
    _tracked = -1;
    for (var i = 0; i < l.placements.length; i++) {
      if (!l.placements[i].fixed) {
        _tracked = i;
        break;
      }
    }
  }

  static bool _sameKey(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final rect = danmakuContainRect(
          Size(box.maxWidth, box.maxHeight),
          widget.aspect,
        );
        if (rect == null) return const SizedBox.shrink();

        if (widget.enabled && widget.comments.isNotEmpty) {
          _ensureLayout(Size(rect.width, rect.height));
        }
        _syncTicker();

        final index = _index;
        final layout = _layout;
        if (!widget.enabled ||
            index == null ||
            layout == null ||
            index.length == 0) {
          return _badgeOnly(rect);
        }

        return Stack(
          children: [
            Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size(rect.width, rect.height),
                  painter: _DanmakuPainter(
                    layout: layout,
                    index: index,
                    clock: () => _t,
                    opacity: widget.opacity,
                    cache: _cache,
                    tracked: _tracked,
                    repaint: _repaint,
                  ),
                ),
              ),
            ),
            if (widget.badge != null && widget.badge!.isNotEmpty)
              Positioned(
                left: rect.left + Sp.x2,
                top: rect.top + Sp.x2,
                child: _badge(widget.badge!),
              ),
          ],
        );
      },
    );
  }

  Widget _badgeOnly(Rect rect) {
    final b = widget.badge;
    if (b == null || b.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned(
          left: rect.left + Sp.x2,
          top: rect.top + Sp.x2,
          child: _badge(b),
        ),
      ],
    );
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.x2,
        vertical: Sp.x1,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.xs),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: FontSizes.cap,
        ),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.layout,
    required this.index,
    required this.clock,
    required this.opacity,
    required this.cache,
    required this.tracked,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final DanmakuLayout layout;
  final _LayoutIndex index;

  /// 读当前时刻（由宿主 State 维护，见文件头的时钟推导）
  final double Function() clock;

  final double opacity;
  final _TextCache cache;

  /// 被跟踪的滚动弹幕下标（探针用）
  final int tracked;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock();
    final vis = index.visibleAt(t);

    /*
     * ★ 逐帧相交检测（**与单测同一判据**，但这里跑的是真实渲染路径）
     *
     * 单测证明的是"分配器算出来的不重叠"；这里证明的是
     * "渲染层画出来的也不重叠" —— 两者都成立，验收点才算真的成立。
     */
    var overlapPairs = 0;
    final boxes = <DanmakuBox>[];
    for (final p in vis) {
      final b = p.boxAt(t, layout.canvasWidth, layout.lineHeight);
      for (final o in boxes) {
        if (o.overlaps(b)) overlapPairs++;
      }
      boxes.add(b);
    }

    double? trackedLeft;
    if (tracked >= 0 && tracked < index.length) {
      final p = index.sorted[tracked];
      if (p.visibleAt(t)) {
        trackedLeft = p.boxAt(t, layout.canvasWidth, layout.lineHeight).left;
      }
    }

    debugDanmakuPaintedFrames++;
    if (overlapPairs > 0) {
      debugDanmakuOverlapFrames++;
      if (overlapPairs > debugDanmakuMaxOverlapPairs) {
        debugDanmakuMaxOverlapPairs = overlapPairs;
      }
    }
    debugDanmakuLastStats = DanmakuRenderStats(
      laneCount: layout.laneCount,
      placed: layout.length,
      dropped: layout.dropped,
      visible: vis.length,
      time: t,
      canvasWidth: layout.canvasWidth,
      canvasHeight: layout.canvasHeight,
      fontSize: vis.isEmpty ? 0 : vis.first.fontSize,
      speedPxPerSecond: layout.speed,
    );
    if (debugDanmakuFrames.length < kDanmakuMaxProbeFrames) {
      debugDanmakuFrames.add(
        DanmakuFrameSample(
          time: t,
          trackedLeft: trackedLeft,
          visible: vis.length,
          overlapPairs: overlapPairs,
        ),
      );
    } else {
      debugDanmakuFramesTruncated = true;
    }

    // 先画所有描边、再画所有填充 —— 否则后画的那条描边会压住前一条的字
    for (final p in vis) {
      final left = p.boxAt(t, layout.canvasWidth, layout.lineHeight).left;
      cache
          .get(
            text: p.comment.text,
            fontSize: p.fontSize,
            color: Color(0xFF000000 | p.comment.color),
            opacity: opacity,
          )
          .stroke
          .paint(canvas, Offset(left, p.laneTop));
    }
    for (final p in vis) {
      final left = p.boxAt(t, layout.canvasWidth, layout.lineHeight).left;
      cache
          .get(
            text: p.comment.text,
            fontSize: p.fontSize,
            color: Color(0xFF000000 | p.comment.color),
            opacity: opacity,
          )
          .fill
          .paint(canvas, Offset(left, p.laneTop));
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.layout != layout || old.opacity != opacity || old.index != index;
}