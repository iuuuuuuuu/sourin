// ignore_for_file: prefer_interpolation_to_compose_strings
// ignore_for_file: library_private_types_in_public_api

/*
 * ★★★ task-104 二期：浮层**退场**动效 —— **真进程**取证探针
 *
 * # 用户原话（逐字）
 *
 * > 第 7 条只做了一半：进入动画做了（遮罩 + 卡片 + 五处面板），
 * > 退出动画和 18 处普通 showDialog 没做。做了吧,顺便要统一一下
 *
 * # 为什么必须真进程
 *
 * ```text
 * flutter_tester 里点不动播放页（_load() 必然失败 —— sourin_core.dll 找不到），
 * 而「关闭时也有动画」这条的本质是**时间轴上的逐帧不透明度**：
 * 要在**真实 vsync 帧**上采样 Opacity，并确认它 260ms 内单调降到 0。
 * widget 测试（test/t104_overlay_exit_test.dart）用的是假时钟 + 手动 pump，
 * 它能证明「逻辑对」，但不能证明「真机上真的是这个观感」。
 * ```
 *
 * # 判据（每条都有阳性对照）
 * ```text
 * ① 打开面板 ⇒ 面板在树上、不透明度 == 1.0
 * ② 关闭面板 ⇒ **第 1 帧仍在树上**（改前：同帧消失 = 一帧硬切）
 * ③ 退出期间逐帧采样 ⇒ 不透明度**单调下降**且至少有一个中间值
 * ④ 退出跑完 ⇒ 面板真的卸载（不会永远盖着）
 * ⑤ showDialog 路由的 transitionDuration == token（150 → 260）
 * ```
 *
 * # 与 test/t104_overlay_exit_test.dart 的分工
 * ```text
 * test/  假时钟、可控帧、能读任意 Widget 类型 —— 证明**逻辑**
 * 本探针 真进程、真 vsync、真 mpv —— 证明**观感**（同一判据的另一支尺子）
 * ```
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'ui/app_scaffold.dart';
import 'ui/app_theme.dart';

/// 探针输出（真机用；stdout 会被父进程写进 t104_out.log）
final List<String> _log = <String>[];
void say(String s) {
  _log.add(s);
  // ignore: avoid_print
  print(s);
}

int _pass = 0;
int _fail = 0;
void ok(String label, bool cond, [String? why]) {
  if (cond) {
    _pass++;
    say('  PASS  ' + label);
  } else {
    _fail++;
    say('  FAIL  ' + label + (why == null ? '' : '  ← ' + why));
  }
}

Future<void> finish(int code) async {
  say('');
  say('== T104 PROBE pass=' + _pass.toString() + ' fail=' + _fail.toString() + ' ==');
  try {
    final f = File('t104_probe_log.txt');
    f.writeAsStringSync(_log.join('\n'));
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(code);
}

Element? _root;
Element? _findFirst(Element e, bool Function(Widget) test) {
  if (test(e.widget)) return e;
  Element? hit;
  e.visitChildren((c) {
    if (hit != null) return;
    hit = _findFirst(c, test);
  });
  return hit;
}

/// 树上第一个 [SheetExitMotion] 的**实际 Opacity**（最外层那个）
double? exitOpacity() {
  if (_root == null) return null;
  final host = _findFirst(_root!, (w) => w is SheetExitMotion);
  if (host == null) return null;
  final op = _findFirst(host, (w) => w is Opacity);
  if (op == null) return null;
  return (op.widget as Opacity).opacity;
}

bool exitHostPresent() =>
    _root != null && _findFirst(_root!, (w) => w is SheetExitMotion) != null;

/// 某个类型的面板是否在树上
bool panelPresent(bool Function(Widget) test) =>
    _root != null && _findFirst(_root!, test) != null;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  /*
   * ★★★ 必须在这里初始化 media_kit —— 与 lib/main.dart:35 / lib/shell.dart:287 同款。
   *
   * 第一版探针漏了这一步，实测（真机 t104_out.log）：
   * ```text
   * Exception: MediaKit.ensureInitialized must be called before using any API
   * #3  _PlayerPageState.initState (player_page.dart:1766)
   * ```
   * ⇒ PlayerPage 的 initState 就炸 ⇒ 整棵树只建了一半 ⇒
   *   连我自己的 SheetExitMotion 都读不到（「阳性对照：SheetExitMotion 在树上」红）。
   * ★ 这是**仪器故障**，不是产品故障 —— 先修仪器再谈判据。
   */
  MediaKit.ensureInitialized();

  runApp(const _ProbeApp());
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  _root = WidgetsBinding.instance.rootElement;
  say('root=' + (_root == null ? 'null' : 'ok'));

  try {
    await body();
  } catch (e, st) {
    say('!! 探针异常: ' + e.toString());
    say(st.toString());
  }
  await finish(0);
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    /*
     * ★★★ 必须用 **material_ui** 的 MaterialApp（不是 flutter/material）——
     * 与 lib/shell.dart:52 同一条纪律（见 test/material_split_test.dart）：
     * 用 flutter/material 会拿到 ThemeData.fallback()（亮色），与生产不一致。
     *
     * ★ 外面套 forui 的 FTheme：项目里所有面板都用 FTheme.of(context) 取色
     *   （episode_strip / settings 系），没有祖先时会静默兜底。
     */
    final theme = AppTheme.themeFor(Brightness.dark);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child ?? const SizedBox()),
      home: const PlayerPage(
      provider: 'probe',
      id: 'probe',
      title: 't104 退场实测',
      episodes: <Episode>[
        Episode(id: 'ep1', title: '第1集', url: 'https://x.invalid/1.m3u8'),
        Episode(id: 'ep2', title: '第2集', url: 'https://x.invalid/2.m3u8'),
      ],
      episodeIndex: 0,
      episodeId: 'ep1',
      episodeTitle: '第1集',
      ),
    );
  }
}

// ======================================================================
//  主流程
// ======================================================================

/// 逐帧采样一段时间内的不透明度（真 vsync）
///
/// ★★★ 必须用 `scheduleFrameCallback`（transient），**不是** `addPostFrameCallback`
/// ```text
/// scheduler/binding.dart:608-622  scheduleFrameCallback(cb) {
///                                 if (scheduleNewFrame) scheduleFrame();   ← ★ 主动调度一帧
/// scheduler/binding.dart:818-834  addPostFrameCallback(cb) { _postFrameCallbacks.add(cb); }
///                                 ← **只入队，不调度帧**
/// ```
/// 实测（本探针第一版）：面板已经关掉、没有动画在跑时，用 post-frame 版本
/// **回调永不触发** ⇒ 探针卡死在 `await done.future`（进程活着、日志停在上一行）。
/// 改用 transient 版本后每帧都会重新调度下一帧。
///
/// ⚠️ 仍然加一个**兜底超时**：探针卡死比断言红更难查（没有栈、没有输出）。
Future<List<double?>> sampleOpacity(Duration total) async {
  final out = <double?>[];
  final done = Completer<void>();
  final t0 = DateTime.now();
  void step(Duration _) {
    out.add(exitOpacity());
    if (DateTime.now().difference(t0) >= total) {
      if (!done.isCompleted) done.complete();
      return;
    }
    SchedulerBinding.instance.scheduleFrameCallback(step);
  }
  SchedulerBinding.instance.scheduleFrameCallback(step);
  await Future.any(<Future<void>>[
    done.future,
    Future<void>.delayed(total + const Duration(milliseconds: 900)),
  ]);
  return out;
}

/// 阶段标记（给**外部**抓图脚本看的：它按这个文件的取值决定什么时候按快门）
///
/// ★ 为什么必须这样同步：PrintWindow 是**外部进程**按下去的，
///   而退场只有 260ms —— 靠"跑完脚本再截图"只能抓到终态
///   （第一版抓的两张图 sha256 **完全相同**，等于没抓）。
void stage(String s) {
  try {
    File('t104_stage.txt').writeAsStringSync(s);
  } catch (_) {}
}

Future<void> body() async {
  say('');
  say('=== ① 弹幕设置面板：关闭时也有动画 ===');

  // ── 阳性对照：先真的打开 ──
  final opened = debugPlayerOpenDanmakuSettingsForProbe();
  await Future<void>.delayed(const Duration(milliseconds: 400));
  ok('阳性对照：探针真的打开了面板', opened);
  ok('阳性对照：SheetExitMotion 在树上', exitHostPresent());
  ok('阳性对照：在位时不透明度 == 1.0', (exitOpacity() ?? -1) > 0.999,
      '实测 ' + (exitOpacity()?.toStringAsFixed(3) ?? 'null'));

  // ★ 给外部抓图脚本一个窗口（它会在这里拍「面板开着」那张）
  stage('open');
  await Future<void>.delayed(const Duration(milliseconds: 1600));

  // ── 关闭：逐帧采样 ──
  final closed = debugPlayerCloseDanmakuSettingsForProbe();
  stage('closing');
  final samples = await sampleOpacity(const Duration(milliseconds: 400));
  stage('closed');
  ok('探针真的关掉了面板', closed);
  ok('关闭后仍有帧采到 SheetExitMotion（说明是**淡出**而不是同帧卸载）',
      samples.any((v) => v != null),
      '采到 ' + samples.where((v) => v != null).length.toString() + '/' +
          samples.length.toString() + ' 帧非空');

  final vals = samples.whereType<double>().toList();
  final mid = vals.where((v) => v > 0.02 && v < 0.98).length;
  ok('退出期间存在**中间态**（不是 1 → 0 瞬变）', mid > 0,
      '中间帧 ' + mid.toString() + ' 个；序列=' +
          vals.take(12).map((v) => v.toStringAsFixed(2)).join(','));

  var mono = true;
  for (var i = 1; i < vals.length; i++) {
    if (vals[i] > vals[i - 1] + 0.02) mono = false;
  }
  ok('退出期间不透明度单调不升', mono);

  await Future<void>.delayed(const Duration(milliseconds: 500));
  /*
   * ⚠️ 判据是「**面板**已卸载」，不是「SheetExitMotion 已卸载」——
   *    本件是**常挂**的（这正是它能跑退场动画的前提，见它的类文档）；
   *    退出跑完后它渲染的是 SizedBox.shrink()，而它自己仍在树上。
   *    ★ 第一版我写成了 !exitHostPresent() ⇒ 假红（探针自己的判据错了）。
   */
  ok('退出跑完 ⇒ 面板（child）已卸载', !panelPresent((w) => w is DanmakuSettingsDialog),
      'SheetExitMotion 仍在树上（常挂，符合设计）；opacity=' +
          (exitOpacity()?.toStringAsFixed(3) ?? 'null'));

  say('');
  say('=== ② 三个面板都接上了 SheetExitMotion（静态读数） ===');
  // ⚠️ 真机的 cwd 是 Release 目录，没有 lib/ ⇒ 用绝对路径（探针专用，不进产品）
  const abs = r'D:\WishProject\sourin-flutter-spike\lib\ui\player_page.dart';
  final src = File(abs).readAsStringSync();
  ok('弹幕设置面板挂载点走 SheetExitMotion',
      src.contains('visible: _danmakuSheetOpen,'));
  ok('B 站导入面板挂载点走 SheetExitMotion',
      src.contains('visible: _biliSheetOpen,'));
  ok('字幕面板挂载点走 SheetExitMotion',
      src.contains('visible: _subtitlePanelOpen,'));
  ok('三个面板都传了 fill: false',
      RegExp(r'fill: false,').allMatches(src).length == 3,
      '实测 ' + RegExp(r'fill: false,').allMatches(src).length.toString() + ' 处');

  say('');
  say('=== ③ showDialog 统一入口的时长（真路由读数） ===');
  // ⚠️ 不能用 rootElement 的 context —— 它在 MaterialApp **之上**，
  //    那里没有 Navigator（实测 Navigator.of 抛 null check）。
  //    用播放页自己的 Element context（它在 MaterialApp/Navigator 之下）。
  final pageEl = _root == null ? null : _findFirst(_root!, (w) => w is PlayerPage);
  final ctx = pageEl;
  if (ctx != null) {
    unawaited(showAppDialog<void>(
      context: ctx,
      builder: (_) => const AlertDialog(
        title: Text('t104'),
        content: Text('统一入口'),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final el = _findFirst(_root!, (w) => w is AlertDialog);
    final route = el == null ? null : ModalRoute.of(el);
    ok('showAppDialog 的 transitionDuration == OverlayMotion.cardDuration',
        route?.transitionDuration == OverlayMotion.cardDuration,
        '实测 ' + (route?.transitionDuration.inMilliseconds.toString() ?? 'null') +
            'ms，期望 ' + OverlayMotion.cardDuration.inMilliseconds.toString() + 'ms');
    Navigator.of(ctx).pop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  say('');
  say('=== ④ 真机渲染快照（肉眼复核用） ===');
  say('  面板打开 / 关闭中途 / 关闭完成 三张图由 t104_probe.py 抓');
}
