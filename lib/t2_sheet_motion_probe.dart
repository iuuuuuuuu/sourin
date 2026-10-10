// ═══════════════════════════════════════════════════════════════════════
//  task-2【⑥】选集抽屉「阻尼太重」 —— 逐帧时序取证探针（2026-10-09）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真机逐帧量，单测证不了
//
// 用户报的是一个运动观感：「阻尼太重」。它不是对/错，是一条时间曲线。
// widget 测试里 pump(Duration) 走的是假时钟，只能证明终值对，
// 证不了「前 130ms 到底走了多少」。
// ⇒ 只有真实进程里逐帧采 Opacity 与 Transform.translate 的实际数值，
//    才能把「阻尼」变成可对比的两个数。
//
// # 这条缺陷的量化定义（改前基线，源码推算得来）
//
//   入场  OverlayCardMotion + Motion.easeOut = Cubic(0.22,1,0.36,1)
//         260ms 内进度 26ms:40.1% 52:67.4% 78:83.2% 90:87.8% 130:96.1%
//         ⇒ 前 90ms 走完 87.8%（一冲一顿）
//   退场  SheetTransition 控制器线性 1→0，easeOut 叠在线性值上
//         t（透明度与位移共用）130ms 时 = 0.9614
//         ⇒ 前 130ms 几乎不动（先冻住再啪一下）
//
// # 本次改动后应当看到的形状
//
//   入场  Curves.easeInOutCubic（对称）⇒ 90ms 应在 ~50% 附近，而非 87.8%
//   退场  透明度走 OverlayMotion.exitFade = Curves.easeIn（前段掉得快）
//         位移   走 OverlayMotion.settle   = Cubic(0.4,0,0.2,1)
//         ⇒ 130ms 时透明度应明显低于 0.9614
//
// # 仪器：读真实渲染树上的两个值
//
//   ① 透明度 —— 找 Opacity 元素，读它 widget 的 opacity
//   ② 位移   —— 读面板本体的 renderObject.localToGlobal(Offset.zero)
//                （localToGlobal 会把祖先 Transform.translate 算进去）
// ★ 只读生产那棵树，不插桩、不改生产代码。
//
// # 两极对照（本仓纪律：没有阳性对照的读数不是读数）
//
// 同一个探针、同一台仪器跑两次构建：
//   极 A（修复后）  EXPECT=post
//   极 B（还原改前）EXPECT=pre
// ★ 极 B 的唯一目的是证明仪器能检出这条缺陷 ——
//   否则极 A 的「90ms 50%」既可能是修复生效，也可能是仪器根本没采到帧。
//
// # 用法
//   flutter build windows --release -t lib/t2_sheet_motion_probe.dart `
//     "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t2m-data" `
//     "--dart-define=EXPECT=post"
// ⚠️ 必须用隔离数据目录（挂了真实的主题/偏好读取链）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'core/models.dart' show Episode;
import 'ui/app_theme.dart';
import 'ui/app_scaffold.dart';
import 'ui/widgets/episode_strip.dart' show EpisodePanel, SheetTransition;

/// 本构建期望看到哪一极（post = 修复后；pre = 改前）
const kExpect = String.fromEnvironment('EXPECT', defaultValue: 'post');

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

final List<String> _log = [];
void say(String s) {
  _log.add(s);
  debugPrint('[T2M] $s');
}

int pass = 0;
int fail = 0;
void ok(String label, bool cond, [String extra = '']) {
  final line = '$label${extra.isEmpty ? '' : '  $extra'}';
  if (cond) {
    pass++;
    _log.add('✓ $line');
    debugPrint('[T2M] ✓ $line');
  } else {
    fail++;
    _log.add('✗ $line');
    debugPrint('[T2M] ✗ $line');
  }
}

void note(String s) {
  _log.add('· $s');
  debugPrint('[T2M] · $s');
}

/// 写产物文件，然后退出
///
/// ★ exit() 不展开 finally ⇒ 每条退出路径都必须先调用本函数。
Future<Never> finish(int code) async {
  try {
    final f = File('$_outDir\\t2m-run-$kExpect.txt');
    f.writeAsStringSync('${_log.join('\n')}\n');
    debugPrint('[T2M] 产物已写 ${f.path} (${f.lengthSync()} B)');
  } catch (e) {
    debugPrint('[T2M] ★ 写产物失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

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

// ═══════════════════════════════════════════════════════════════════════
//  元素树定位
// ═══════════════════════════════════════════════════════════════════════

Element? findText(Element root, String text) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final wd = e.widget;
    if (wd is Text && wd.data == text) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 面板本体：`Text('选集')` 往上找第一个带 BoxDecoration 的 Container
///
/// （`episode_strip.dart` 的 `final box = Container(...)`，它带 card 底色
///   与圆角 ⇒ 是唯一的那个 BoxDecoration 祖先）
Element? findPanelBody(Element root) {
  final label = findText(root, '选集');
  if (label == null) return null;
  Element? hit;
  label.visitAncestorElements((a) {
    final wd = a.widget;
    if (wd is Container && wd.decoration is BoxDecoration) {
      hit = a;
      return false; // 最近的那个，停
    }
    return true;
  });
  return hit;
}

/// 面板此刻在屏幕上的矩形（含祖先 Transform.translate 的位移）
Rect? panelRectNow(Element root) {
  final pn = findPanelBody(root);
  final ro = pn?.renderObject;
  if (ro is! RenderBox || !ro.attached) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 找包着面板本体的那个 Opacity 元素（读它 widget.opacity）
///
/// ★★ task-2【⑥】改前这里取的是**最近**的那个 Opacity，量错了对象：
///   面板本体外面有**两层** Opacity ——
/// ```text
/// 内层 = OverlayCardMotion 的入场淡入（tween 1→0，入场结束后恒 1）
/// 外层 = SheetTransition 的退场淡出（本次要测的就是它）
/// ```
///   退场时内层那个还是 1（入场 tween 早就停在 0 了），而最近原则
///   恰好先撞上它 ⇒ 读数恒 1.0000，看起来像"退场完全不淡出"。
///   ⇒ 改成取**最外**的那个 Opacity（`visitAncestorElements` 一路走到底，
///     最后一个命中的就是最外层）。
///
/// ⚠️ 遮罩（`OverlayScrim`）的 Opacity 在**面板之外**的另一支上，
///   不是面板本体的祖先 ⇒ 不会被这一趟抓到。
double? opacityOfPanel(Element root) {
  final pn = findPanelBody(root);
  if (pn == null) return null;
  double? found;
  pn.visitAncestorElements((a) {
    final wd = a.widget;
    if (wd is Opacity) found = wd.opacity; // 不 return false ⇒ 一路走到最外层
    return true;
  });
  return found;
}

// ═══════════════════════════════════════════════════════════════════════
//  帧采样
// ═══════════════════════════════════════════════════════════════════════

Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 逐帧采（相对起点 ms, 面板矩形, 面板 opacity）
typedef Sample = (double, Rect?, double?);

Future<List<Sample>> sample(
  Element root,
  Duration maxTotal, {
  bool stopWhenGone = false,
  int maxFrames = 400,
  VoidCallback? onFirstFrame,
}) async {
  final out = <Sample>[];
  final t0 = DateTime.now();
  var everSeen = false;
  var first = true;
  while (true) {
    // TRIGGER 放在 pump 之前：调用方想在"采样一开始"就改变状态
    // （例如点关闭 → 面板开始退场）。当前一次 pump 已把面板画出来，
    // 此刻置 false 会让**紧接着的**这一帧进入退场支 ✓（上一版放在
    // pump 之后，退出支在采样循环的下一轮才生效，中间那轮把
    // `_mounted=false` 也画了出去 ⇒ 只采到 1 帧）。
    if (first) {
      first = false;
      onFirstFrame?.call();
    }
    await pumpFrame();
    final ms = DateTime.now().difference(t0).inMicroseconds / 1000.0;
    final rr = panelRectNow(root);
    final oo = opacityOfPanel(root);
    out.add((ms, rr, oo));
    if (rr != null) everSeen = true;
    if (stopWhenGone && everSeen && rr == null) break;
    if (DateTime.now().difference(t0) >= maxTotal) break;
    if (out.length >= maxFrames) break;
  }
  return out;
}

double progressAt(List<(double, double)> pts, double ms) {
  if (pts.isEmpty) return -1;
  (double, double)? best;
  for (final q in pts) {
    if (best == null || (q.$1 - ms).abs() < (best.$1 - ms).abs()) best = q;
  }
  return best!.$2;
}

double? opacityAt(List<Sample> ss, double ms) {
  Sample? best;
  for (final s in ss) {
    if (best == null || (s.$1 - ms).abs() < (best.$1 - ms).abs()) best = s;
  }
  return best?.$3;
}

// ═══════════════════════════════════════════════════════════════════════
//  探针外壳：真实挂 EpisodePanel（生产那棵树）
// ═══════════════════════════════════════════════════════════════════════

final _rootKey = GlobalKey();

/// 驱动开关：_open 变化 ⇒ SheetTransition 走进入/退出支
///
/// ★ 与生产完全同构：`player_page.dart` 就是
///   SheetTransition(visible: _episodeSheetOpen, child: EpisodePanel(...))。
///   这里逐字复用生产 SheetTransition（不是副本）。
bool _open = false;

void Function(void Function()) _probeSetState = (_) {};

void setOpen(bool v) => _probeSetState(() => _open = v);

class ProbeHost extends StatefulWidget {
  const ProbeHost({super.key, required this.episodes});
  final List<Episode> episodes;
  @override
  State<ProbeHost> createState() => ProbeHostState();
}

class ProbeHostState extends State<ProbeHost> {
  @override
  void initState() {
    super.initState();
    _probeSetState = (fn) => setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF101014),
      child: Stack(
        children: [
          // 背景参照物（自检用：证明真的渲染了东西）
          Positioned(
            left: 8,
            bottom: 8,
            child: Text(
              'task-2 6 探针背景',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
            ),
          ),
          // ★ task-2【⑥】改前这里写的是 `if (_open) Positioned.fill(...)`
          //   —— 错在哪：`_open` 变 false 的那一帧整棵 SheetTransition
          //   被**从树上摘掉**，退场动画根本没机会渲染（探针据此只能
          //   采到 0~1 帧全 "面板已从树上移除"）。
          //   生产 `player_page.dart:10659-10676` 是**无条件常挂**
          //   `Positioned.fill(child: SheetTransition(visible: _episodeSheetOpen, ...))`，
          //   靠 `visible` 驱动进出；探针必须与生产同构 ⇒ 去掉这个 if。
          Positioned.fill(
            child: SheetTransition(
              visible: _open,
                slideFrom: const Offset(24, 0), // PC 右侧抽屉方向
                child: EpisodePanel(
                  episodes: widget.episodes,
                  currentIndex: 0,
                  onPick: (_) {},
                  onClose: () => setOpen(false),
                  isDesktopOverride: true, // 强制 PC 形态 = rightDrawer
              ),
            ),
          ),
        ],
      ),
    );
  }
}

List<Episode> _fakeEpisodes(int n) => [
  for (var i = 0; i < n; i++)
    Episode(
      id: 'e$i',
      title: '第 ${i + 1} 集',
      url: 'https://probe.invalid/$i.m3u8',
    ),
];

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await _resolveDataDir();
  debugPrint('[T2M] ====== task-2(6) 选集抽屉阻尼 —— 逐帧取证 ======');
  say('数据目录: $dir');
  say('期望极: kExpect=$kExpect');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-2(6) 抽屉阻尼探针');
  }

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale("zh", "CN"), Locale("en", "US")],
        builder: (context, child) => AppThemeHost(
          data: AppTheme.themeFor(Brightness.light),
          child: AppScaffold(
            child: Material(type: MaterialType.transparency, child: child!),
          ),
        ),
        home: ProbeHost(episodes: _fakeEpisodes(12)),
      ),
    ),
  );

  await Future<void>.delayed(const Duration(milliseconds: 900));

  // ★ currentContext 的静态类型是 BuildContext，但实际对象是 Element
  //   ——根节点就是 Element 树上的一个节点，转成 Element 才能 visitChildren。
  final root = _rootKey.currentContext as Element?;
  if (root == null) {
    say('★ 根元素没挂上 ⇒ 中止');
    await finish(1);
  }

  // ── 0 仪器自检（无极对照）──
  debugPrint('[T2M]');
  debugPrint('[T2M] ── 0 仪器自检 ──');
  ok('面板关着时定位链找不到它（无极对照）', panelRectNow(root) == null,
      'rect=${panelRectNow(root)}');

  // ── 1 打开 ⇒ 入场逐帧 ──
  debugPrint('[T2M]');
  debugPrint('[T2M] ── 1 入场：逐帧 opacity + offset ──');
  // ★ 入场窗口 340ms 足够覆盖 260ms 动画 + 余量。
  //   历史踩过：入场窗口给太大（700ms）会把外层总预算吃光，
  //   退场段还没跑就被外层超时杀掉 ⇒ 只留下入场读数。
  final entryF = sample(root, const Duration(milliseconds: 340));
  setOpen(true);
  final entry = await entryF;

  final entrySeen = [
    for (final s in entry)
      if (s.$2 != null) s,
  ];
  if (entrySeen.isEmpty) {
    say('★ 打开后一帧都没定位到面板 ⇒ 定位链坏了，中止');
    await finish(1);
  }
  final rest = entrySeen.last.$2!;
  say('面板静止矩形 left=${rest.left.toStringAsFixed(1)} '
      'top=${rest.top.toStringAsFixed(1)} '
      'w=${rest.width.toStringAsFixed(1)} h=${rest.height.toStringAsFixed(1)}');

  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final screenW = view.physicalSize.width / view.devicePixelRatio;
  // ★ 容差 15：窗口物理宽 1280 里含非客户区/边框 ⇒ 客户区右边缘在 1268
  //   （实测，见本次读数）。判据是「贴右边且是窄的右侧抽屉」，不是逐像素。
  ok('仪器自检：面板是右侧抽屉（贴右边 + 宽 380）',
      (rest.right - screenW).abs() < 15 && (rest.width - 380).abs() < 2,
      'right=${rest.right.toStringAsFixed(1)} 屏宽=$screenW '
      '宽=${rest.width.toStringAsFixed(1)}');

  say('');
  say('入场逐帧（ms, opacity, dx, dy）:');
  for (final s in entry) {
    final rc = s.$2;
    if (rc == null) {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   (未定位到)');
    } else {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   '
          'op=${(s.$3 ?? -1).toStringAsFixed(4).padLeft(7)}   '
          'dx=${(rc.left - rest.left).toStringAsFixed(2).padLeft(7)}   '
          'dy=${(rc.top - rest.top).toStringAsFixed(2).padLeft(7)}');
    }
  }

  // 入场进度：用位移算 p（dx 从 24 到 0）
  final entryPts = <(double, double)>[];
  for (final s in entry) {
    final rc = s.$2;
    if (rc == null) continue;
    final dx = rc.left - rest.left;
    entryPts.add((s.$1, (1 - dx / 24.0).clamp(0.0, 1.0)));
  }

  final p90 = progressAt(entryPts, 90);
  final p130 = progressAt(entryPts, 130);
  final p260 = progressAt(entryPts, 260);
  note('入场进度 p(90ms)=${p90.toStringAsFixed(4)} '
      'p(130ms)=${p130.toStringAsFixed(4)} '
      'p(260ms)=${p260.toStringAsFixed(4)}');

  // ── 2 关闭 ⇒ 退场逐帧 ──
  debugPrint('[T2M]');
  debugPrint('[T2M] ── 2 退场：逐帧 opacity + offset ──');
  // ★ maxFrames=60：`_c.reverse().whenComplete` 里挂的是 setState，
  //   退出完成后若还有别的调度源持续请求帧，endOfFrame 会一直被满足，
  //   采样循环就停不下来（历史踩过：进程被外层超时杀掉、不留产物）。
  //   260ms 动画 × 60fps ≈ 16 帧，给 60 帧足够覆盖整段。
  say('DIAG 关闭前 _open=$_open panelFound=${panelRectNow(root) != null}');
  final exitF = sample(root, const Duration(milliseconds: 900),
      stopWhenGone: true, maxFrames: 60, onFirstFrame: () => setOpen(false));
  final exit = await exitF;
  say('DIAG 退场采样返回 ${exit.length} 帧，末帧 t=${exit.isEmpty ? "-" : exit.last.$1.toStringAsFixed(1)}');

  say('');
  say('退场逐帧（ms, opacity, dx, dy）:');
  for (final s in exit) {
    final rc = s.$2;
    if (rc == null) {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   (面板已从树上移除)');
    } else {
      say('    ${s.$1.toStringAsFixed(1).padLeft(7)}   '
          'op=${(s.$3 ?? -1).toStringAsFixed(4).padLeft(7)}   '
          'dx=${(rc.left - rest.left).toStringAsFixed(2).padLeft(7)}   '
          'dy=${(rc.top - rest.top).toStringAsFixed(2).padLeft(7)}');
    }
  }

  // ★ 诊断：把面板本体到根之间**所有** Opacity 祖先打出来 ——
  //   退场读数里 dx 在动而 opacity 恒 1.0000，怀疑量到的是内层
  //   （入场 OverlayCardMotion）的那个 Opacity，而不是 SheetTransition 的。
  {
    final pn = findPanelBody(root);
    if (pn != null) {
      final chain = <String>[];
      pn.visitAncestorElements((a) {
        final wd = a.widget;
        if (wd is Opacity) {
          chain.add('${wd.runtimeType}@op=${wd.opacity.toStringAsFixed(4)}');
        } else if (wd is AnimatedBuilder) {
          chain.add('AnimatedBuilder');
        } else if (wd is Transform) {
          chain.add('Transform');
        }
        return true;
      });
      say('DIAG Opacity 祖先链（由内向外）: ${chain.join(" | ")}');
    }
  }

  final exitSeen = [
    for (final s in exit)
      if (s.$2 != null) s,
  ];
  ok('2 退场段采到了帧', exitSeen.isNotEmpty, '${exitSeen.length} 帧');

  final op65 = opacityAt(exitSeen, 65);
  final op130 = opacityAt(exitSeen, 130);
  note('退场 opacity(65ms)=${op65?.toStringAsFixed(4)} '
      'opacity(130ms)=${op130?.toStringAsFixed(4)}  '
      '（改前基线 130ms = 0.9614）');

  // ── 3 判读 ──
  debugPrint('[T2M]');
  debugPrint('[T2M] ── 3 判读（期望极 = $kExpect）──');
  if (kExpect == 'post') {
    ok('1 入场 90ms 进度 < 0.75 ⇒ 不再是改前的前段狂冲',
        p90 >= 0 && p90 < 0.75,
        'p(90ms)=${p90.toStringAsFixed(4)} （改前基线 0.878）');
    ok('2 退场 130ms 透明度 < 0.90 ⇒ 不再是改前的先冻住',
        op130 != null && op130 < 0.90,
        'opacity(130ms)=${op130?.toStringAsFixed(4)} （改前基线 0.9614）');
  } else {
    ok('1【极B】入场 90ms 进度 >= 0.80 ⇒ 复现改前前段狂冲',
        p90 >= 0.80, 'p(90ms)=${p90.toStringAsFixed(4)}');
    ok('2【极B】退场 130ms 透明度 >= 0.93 ⇒ 复现改前先冻住',
        op130 != null && op130 >= 0.93,
        'opacity(130ms)=${op130?.toStringAsFixed(4)}');
  }

  say('');
  say('VERDICT expect=$kExpect '
      'entryP90=${p90.toStringAsFixed(4)} '
      'entryP130=${p130.toStringAsFixed(4)} '
      'entryP260=${p260.toStringAsFixed(4)} '
      'exitOp65=${op65?.toStringAsFixed(4)} '
      'exitOp130=${op130?.toStringAsFixed(4)} '
      'entryFrames=${entrySeen.length} exitFrames=${exitSeen.length}');
  say('RESULT expect=$kExpect verdict=${fail == 0 ? 'PASS' : 'FAIL'} '
      'pass=$pass fail=$fail');

  await finish(fail == 0 ? 0 : 1);
}
