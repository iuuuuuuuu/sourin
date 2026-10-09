// ══════════════════════════════════════════════════════════════════════
//  t458 —— 真机进程内拖拽自检（Owner 要求「拟人化操作试试看」）
// ══════════════════════════════════════════════════════════════════════
//
// # ⚠️⚠️ 本文件第一版**测错了宿主**（2026-10-01，必须记下来）
//
// `skip_marker_dialog.dart:1474` 的注释**明确写着**：
// ```text
// 「探针里**单独**放 SkipTimeline（无外层滚动）时，拖拽 100% 成功
//   —— 所以问题只出在弹窗这个组合里」
// ```
// ★ 而我第一版的宿主是 `Center > SizedBox > SkipTimeline` ——
//   **正是那个"已知能成功"的配置**！
// ⇒ 它 `VERDICT: PASS` 了，而**什么也没证明**。
// ⇒ Owner 随后说「那个三角根本就不能拖动」—— 他是对的。
//
// ★★ 教训：**验证必须复现缺陷所在的配置**。
//    我修了一个 bug，然后在一个**已知不触发该 bug 的宿主**上验证 ——
//    那等于没验。
//
// # 现在：宿主就是**真实的 `SkipMarkerDialog`**
//
// 不抽 `SkipTimeline` 单独测，而是把整个弹窗挂起来。
//
// # 本自检要覆盖的两个场景（都必须在**真实弹窗**里）
// ```text
// ① 端点**全未设置**时拖幽灵箭头  ← Owner 实际遇到的场景（他打开时没设过）
// ② 端点已设置时拖实心箭头        ← 另一种场景
// ```
//
// # 为什么需要"进程内"
//
// 我写了三版**外部鼠标驱动**脚本（`.probe\t455/t456/t457`），
// 全部卡在同一处：**两块屏幕都被占满了**
// （主屏 VS Code 全屏、副屏两个 qemu）⇒ 没有 1280x800 的空位
// ⇒ `WindowFromPoint` 的落点校验（必要的保护，实测挡住过两次）拒绝所有落点。
// ★ 我不能为了测试去关掉 Owner 正在用的应用。
//
// ⇒ 用 `GestureBinding.instance.handlePointerEvent` 发**真实指针事件**
//   —— 与物理鼠标**同一条管线**，只是不经过操作系统光标。
//
// ⚠️ **默认关**（`SOURIN_DRAG_SELFTEST=1` 才跑）⇒ 生产行为逐字不变。
//
// 用法：
// ```powershell
// $env:SOURIN_DRAG_SELFTEST='1'; .\sourin_spike.exe
// # 结果写到 %TEMP%\sourin_drag_selftest.txt
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';
import 'ui/app_scaffold.dart';
import 'ui/app_theme.dart';

/// 自检是否启用（环境变量控制，**默认关** ⇒ 生产行为不变）
bool get dragSelfTestEnabled =>
    Platform.environment['SOURIN_DRAG_SELFTEST'] == '1';

Future<void> runDragSelfTest(StringBuffer sink) async {
  void log(String s) {
    sink.writeln(s);
    // ignore: avoid_print
    print('[DRAG-SELFTEST] $s');
  }

  runApp(_SelfTestApp(log: log, sink: sink));
}

Future<void> _settle(int ms) async {
  final c = Completer<void>();
  SchedulerBinding.instance.addPostFrameCallback((_) => c.complete());
  SchedulerBinding.instance.scheduleFrame();
  await Future.any([
    c.future,
    Future<void>.delayed(Duration(milliseconds: ms)),
  ]);
  await Future<void>.delayed(Duration(milliseconds: ms));
}

void _finish(StringBuffer sink, String verdict) {
  sink.writeln('VERDICT: $verdict');
  final f = File(
    '${Platform.environment['TEMP'] ?? '.'}\\sourin_drag_selftest.txt',
  );
  f.writeAsStringSync(sink.toString());
  // ignore: avoid_print
  print('[DRAG-SELFTEST] VERDICT: $verdict');
  // ignore: avoid_print
  print('[DRAG-SELFTEST] 已写入 ${f.path}');
  exit(0);
}

// ─────────────────────────────────────────────────────────────────────
//  宿主 = **真实弹窗**（不是复刻品）
// ─────────────────────────────────────────────────────────────────────

class _SelfTestApp extends StatelessWidget {
  const _SelfTestApp({required this.log, required this.sink});

  final void Function(String) log;
  final StringBuffer sink;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.themeFor(Brightness.light);
    return MaterialApp(
      theme: theme,
      builder: (context, c) =>
          AppThemeHost(data: theme, child: c ?? const SizedBox()),
      home: _SelfTestPage(log: log, sink: sink),
    );
  }
}

class _SelfTestPage extends StatefulWidget {
  const _SelfTestPage({required this.log, required this.sink});

  final void Function(String) log;
  final StringBuffer sink;

  @override
  State<_SelfTestPage> createState() => _SelfTestPageState();
}

class _SelfTestPageState extends State<_SelfTestPage> {
  /// 在**整棵树**里找 `SkipTimeline` 的 `Element`
  ///
  /// ⚠️ 我第一版写的是 `find.byType(SkipTimeline)` —— 那是 **`flutter_test`
  ///    的 API**，生产代码里没有。
  /// ★ 而"给生产 widget 加一个 `timelineKey` 参数"我也不想做 ——
  ///   那是**为了测试而改生产 API**，会让下一个人以为它有用。
  /// ⇒ 正确做法：自己走 `Element` 树（`visitChildren` 是框架公开 API）。
  Element? _findTimeline(Element root) {
    if (root.widget is SkipTimeline) return root;
    Element? found;
    root.visitChildren((child) {
      found ??= _findTimeline(child);
    });
    return found;
  }

  Element? get _tlElement {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    return _findTimeline(root);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 800), () => unawaited(_run()));
    });
  }

  SkipTimeline? get _tl {
    final e = _tlElement;
    return e?.widget is SkipTimeline ? e!.widget as SkipTimeline : null;
  }

  RenderBox? get _tlBox =>
      _tlElement?.findRenderObject() as RenderBox?;

  /// 在**真实弹窗**里拖一个端点
  ///
  /// [ghost] 为 true 时起点用**幽灵位置**（模拟"用户看到三角就去拖"）。
  Future<int?> _dragEdge(
    String label, {
    required SkipEdge edge,
    required bool ghost,
  }) async {
    final log = widget.log;
    final tl = _tl;
    final box = _tlBox;
    if (tl == null || box == null) {
      log('!! $label：找不到时间轴（tl=${tl != null} box=${box != null}）');
      return null;
    }
    final size = box.size;
    final origin = box.localToGlobal(Offset.zero);

    double startLocal;
    if (ghost) {
      final g = ghostTipFor(
        edge: edge,
        width: size.width,
        inset: kArrowInset,
        arrowW: kArrowW,
      );
      startLocal = skipEdgeBodyCenter(edge, g)!;
    } else {
      final tips = computeSkipTips(
        width: size.width,
        total: tl.total,
        introStart: tl.introStart,
        introEnd: tl.introEnd,
        outroStart: tl.outroStart,
        outroEnd: tl.outroEnd,
      );
      final t = tips[edge];
      if (t == null) {
        log('!! $label：端点未设置，无法用实心位置');
        return null;
      }
      startLocal = skipEdgeBodyCenter(edge, t)!;
    }

    final left = edge == SkipEdge.introStart || edge == SkipEdge.introEnd;
    final targetLocal = left ? size.width * 0.30 : size.width * 0.70;

    final y = origin.dy + size.height / 2;
    final from = Offset(origin.dx + startLocal, y);
    final to = Offset(origin.dx + targetLocal, y);
    log('$label 起点=$from 终点=$to（ghost=$ghost）');
    /*
     * ★ 诊断用读数（第 3 次运行 `introStart` 间歇性拖不动，需要证据不是猜测）：
     * ```text
     * origin/size  —— 弹窗布局是否已经稳定（rect 会随动画/滚动变）
     * startLocal   —— 我算的抓取点
     * ```
     */
    log('  诊断: origin=$origin size=$size startLocal=$startLocal');
    /*
     * ★★ 诊断（50% 间歇失败，需要**读数**不是猜测）
     *
     * 失败时的现象：`introStart`（**第一个**被拖的）拿不到，
     * 而后面三个都正常 ⇒ 指向**时序**：第一次交互时弹窗还没稳定。
     *
     * ⇒ 这里把"弹窗是否还在 loading"和"时间轴 rect 是否已稳定"一起打出来。
     *   `_loading` 为 true 时弹窗只显示一个转圈 ⇒ 那时**没有时间轴**，
     *   但我的 `_findTimeline` 会返回 null 并 log —— 而失败那次**没**log 那句
     *   ⇒ 说明时间轴**在**，只是**位置**可能不对（弹窗还在长大）。
     */
    final tlNow = _tl;
    log('  诊断: 时间轴 position=${tlNow?.position} '
        'introStart=${tlNow?.introStart} total=${tlNow?.total}');

    final binding = GestureBinding.instance;
    final pointer = 9200 + edge.index + (ghost ? 10 : 0);

    binding.handlePointerEvent(PointerDownEvent(
      pointer: pointer, position: from, kind: PointerDeviceKind.mouse,
    ));
    await _settle(30);

    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      binding.handlePointerEvent(PointerMoveEvent(
        pointer: pointer,
        position: Offset.lerp(from, to, i / steps)!,
        kind: PointerDeviceKind.mouse,
      ));
      await _settle(30);
    }

    int? valueOf() {
      final w = _tl;
      if (w == null) return null;
      return switch (edge) {
        SkipEdge.introStart => w.introStart,
        SkipEdge.introEnd => w.introEnd,
        SkipEdge.outroStart => w.outroStart,
        SkipEdge.outroEnd => w.outroEnd,
      };
    }

    final during = valueOf();
    binding.handlePointerEvent(PointerUpEvent(
      pointer: pointer, position: to, kind: PointerDeviceKind.mouse,
    ));
    await _settle(60);
    final after = valueOf();
    log('$label 拖动中=$during 松手后=$after');

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 判据用**松手后**的值，不是"拖动中"（2026-10-02，50% 假红）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 我踩的坑
     * 我原来 `return during;`（拖动中的值）—— 实测**间歇性**返回 null：
     * ```text
     * 幽灵-introStart 拖动中=null 松手后=856   ← ★ 松手后才生效
     * ```
     * 而**同一个端点**在别的运行里"拖动中"就是 856。
     *
     * # 为什么（这不是产品 bug）
     * `onChanged` 里是 `setState(() => _introStart = value)` ——
     * 它要**下一帧**才反映到我读的 `widget.introStart` 上。
     * 我的 `_settle(30)` 是"postFrame 回调 **或** 30ms 超时"——
     * ★ 在机器忙的时候会走**超时**那一支 ⇒ 那一帧还没重建完
     *   ⇒ 我读到的是**旧 widget** 的值（null）。
     *
     * ★ 关键：**松手后**读是**稳的** —— 因为那时已经过了好几帧，
     *   且"松手"本身不改变值。
     * ⇒ 判"拖动是否生效"应该看 `after`（松手后的最终值），
     *   它才是"用户拖完之后的状态" —— 也正是 Owner 关心的东西。
     *
     * ⚠️ 而 `during` 仍有价值：它能证明"拖动**过程中**就在更新"
     *    （而不是松手才跳一下）。所以**两个都记**，
     *    但**判据用 after**，`during` 只作为补充读数。
     */
    final ok = after != null;
    log('  ⇒ 判定: ${ok ? "生效" : "未生效"}（以松手后为准）');
    /*
     * ★ 诊断：若 `during == null`，要分清是"没抓住"还是"抓住了但没改值"。
     *   两者修法完全不同：
     * ```text
     * 没抓住   ⇒ hitEdge 返回 null ⇒ 起点坐标/布局问题
     * 抓住了   ⇒ onChanged 没触发 / 值被 clamp 夹回原值
     * ```
     *   ⇒ 用"拖动过程中起点是否仍在同一位置"作间接判据：
     *     若弹窗布局动了（origin 变），起点就落空了。
     */
    final box2 = _tlBox;
    if (box2 != null) {
      final origin2 = box2.localToGlobal(Offset.zero);
      log('  诊断: 拖动后 origin=$origin2 '
          '(拖动前 origin=$origin，'
          '位移=${(origin2 - origin).distance.toStringAsFixed(2)})');
    }
    /*
     * ★★ 关键诊断：**按下点有没有落在时间轴矩形内**。
     *
     * `hitEdge` 用的是 `localPosition` —— 若弹窗在拖动期间**移动了**
     * （比如从"loading 的 200 高"长到完整高度），那么"全局坐标不变"
     * 的指针事件在**新的** local 坐标系里就落到别处了。
     * ⇒ 这里直接把"按下点相对时间轴的位置"打出来。
     */
    final rectAtStart = Rect.fromLTWH(
      origin.dx, origin.dy, size.width, size.height,
    );
    log('  诊断: 按下点 $from 是否在时间轴矩形 $rectAtStart 内 = '
        '${rectAtStart.contains(from)}');
    return after;
  }

  Future<void> _run() async {
    final log = widget.log;
    final sink = widget.sink;

    log('宿主 = **真实 SkipMarkerDialog**（不是裸放的时间轴）');
    log('');

    final tl0 = _tl;
    if (tl0 == null) {
      log('!! 弹窗里找不到时间轴 —— 自检无法继续');
      _finish(sink, 'FAIL: no SkipTimeline');
      return;
    }
    log('初始值 introStart=${tl0.introStart} introEnd=${tl0.introEnd} '
        'outroStart=${tl0.outroStart} outroEnd=${tl0.outroEnd}');

    // ── 场景 ①：端点**全未设置**时拖幽灵箭头（Owner 实际遇到的）──
    log('══ 场景① 端点全未设置 ⇒ 拖幽灵箭头 ══');

    /*
     * ★★★ 2026-10-02：**第一次拖拽有约 1/6 概率失败**（实测 6 次里 1 次）
     *
     * 现象：只有 `introStart`（**第一个**被拖的）拿不到值，
     *       后面三个 100% 正常。而同一位置的 widget 测试（t460）
     *       连续 3 次都是稳定的。
     * ⇒ 差异只能是**真机时序**：自检在 `postFrame + 800ms` 就开始拖，
     *   而弹窗那时可能还在 `_loading`（读 store / 起预览都要等异步）。
     *
     * ★ 本段先**等时间轴真的就绪**再开始，把"时序"这个变量消掉：
     * ```text
     * 就绪判据 = 时间轴存在 且 total > 0
     *            （total 来自 duration，弹窗拿到就一定不在 loading）
     * ```
     * ⚠️ 这不是"为了让它绿而放宽判据" —— 它消除的是**自检自身的时序缺陷**：
     *    用户不会在弹窗刚弹出的第 1 帧就去拖，而我的自检会。
     */
    var readyWaited = 0;
    while (readyWaited < 40) {
      final t = _tl;
      if (t != null && t.total > 0) break;
      await _settle(100);
      readyWaited++;
    }
    log('等时间轴就绪：等了 ${readyWaited * 100}ms  '
        '（total=${_tl?.total}）');

    final ghostResults = <SkipEdge, int?>{};
    for (final e in SkipEdge.values) {
      ghostResults[e] = await _dragEdge('幽灵-${e.name}', edge: e, ghost: true);
    }
    log('幽灵拖动结果 = $ghostResults');
    final ghostOk = ghostResults.values.every((v) => v != null);
    log('① 四个幽灵箭头全部可拖: $ghostOk');
    log('');

    log('══ 判据 ══');
    log('① 幽灵箭头可拖（Owner 报的场景）: $ghostOk');
    log('');

    // ── 场景 ②：拖动后预览必须**停在拖动值**（Owner 第三条）──
    log('══ 场景② 拖动后预览必须停住（状态重置，不继续播）══');
    final samples = <double>[];
    for (var i = 0; i < 20; i++) {
      await _settle(100);
      samples.add(_tl?.position ?? -1);
    }
    log('position 采样 = $samples');
    final tail = samples.skip(6).toList();
    final first = tail.isEmpty ? -1.0 : tail.first;
    final stable = tail.isNotEmpty && tail.every((v) => (v - first).abs() < 0.5);
    log('稳定段首值 = $first  稳定 = $stable');
    final lastEdge = _lastDraggedValue();
    log('最后被拖的端点值 = $lastEdge');
    final stopsAtDrag = lastEdge != null && (first - lastEdge).abs() < 1.5;
    log('② 停在拖动值上: $stopsAtDrag');
    log('');

    // ── 场景 ③：四条互斥（Owner：「箭头不能互相穿过」）──
    log('══ 场景③ 四条互斥：箭头不许互相穿过 ══');
    final t3 = _tl;
    final a = t3?.introStart, b = t3?.introEnd;
    final c = t3?.outroStart, d = t3?.outroEnd;
    log('当前四点 = [$a, $b, $c, $d]');
    final totalSec = t3?.total.toInt() ?? 0;

    var excl = true;
    if (a != null && b != null && !(a < b)) {
      log('!! ① 违反：introStart($a) 必须 < introEnd($b)');
      excl = false;
    }
    if (b != null && c != null && !(b < c)) {
      log('!! ② 违反：introEnd($b) 必须 < outroStart($c) '
          '—— Owner：「片尾的两个箭头不能跑到片头的两个前面去」');
      excl = false;
    }
    if (c != null && d != null && !(c < d)) {
      log('!! ③ 违反：outroStart($c) 必须 < outroEnd($d)');
      excl = false;
    }
    for (final (n, v) in [('introStart', a), ('introEnd', b),
                          ('outroStart', c), ('outroEnd', d)]) {
      if (v != null && (v < 0 || v > totalSec)) {
        log('!! ④ 违反：$n($v) 越界 [0, $totalSec]');
        excl = false;
      }
    }
    log('③ 四条互斥成立: $excl');
    log('');

    log('══ 判据 ══');
    log('① 幽灵箭头可拖（Owner 报的场景）: $ghostOk');
    log('② 拖动后预览停住且停在拖动值:    ${stable && stopsAtDrag}');
    log('③ 四条互斥（箭头不许穿过）:      $excl');
    log('');

    final pass = ghostOk && stable && stopsAtDrag && excl;
    _finish(
      sink,
      pass
          ? 'PASS: 幽灵可拖 + 拖动停住 + 四条互斥'
          : 'FAIL: ghostOk=$ghostOk stable=$stable '
              'stopsAtDrag=$stopsAtDrag excl=$excl',
    );
  }

  /// 场景①里**最后**被拖的那个端点的值（`SkipEdge.values.last`）
  int? _lastDraggedValue() {
    final tl = _tl;
    if (tl == null) return null;
    return switch (SkipEdge.values.last) {
      SkipEdge.introStart => tl.introStart,
      SkipEdge.introEnd => tl.introEnd,
      SkipEdge.outroStart => tl.outroStart,
      SkipEdge.outroEnd => tl.outroEnd,
    };
  }

  @override
  Widget build(BuildContext context) {
    return const SkipMarkerDialog(
      provider: 'selftest',
      id: 't458',
      title: '真机拖拽自检',
      streamUrl: '',
      duration: Duration(minutes: 47, seconds: 6),
    );
  }
}

