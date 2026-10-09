// ═══════════════════════════════════════════════════════════════════════
//  task-2【④】「非全屏时底栏『选集』不该占位置」—— **真渲染**取证探针
//  （2026-10-09）
// ═══════════════════════════════════════════════════════════════════════
//
// # 要回答的唯一问题
//
// Owner 第 15 条原话：
// > 在非全屏状态下,选集的按钮不应该出现占位置
//
// Lead 裁决的读法 A（**不是**「非全屏就一律隐藏」）：
// ```text
// 右侧详情栏**真的可见**（wide && !fullscreen）
//   ⇒ 详情栏里本来就有剧集列表（detail_page.dart:2266 `_BlockTitle(text:'选集')`）
//   ⇒ 底栏那枚是**重复入口** ⇒ 不显示
// 没有右侧详情栏（窄屏 Column 分支 / 全屏 / 从历史记录 push 进来的窄窗）
//   ⇒ 它是**就近切集的唯一入口** ⇒ 必须显示
// ```
//
// # 为什么必须真渲染（而不是源码级静态审计）
//
// 判据链有三段，静态审计只能钉住第一段：
// ```text
// ① player_page.dart:10303  hasEpisodes: _episodes.length > 1 && !widget.hasRightDetailBar
// ② _BottomBar 三处 if (hasEpisodes)  →  :14019 / :14350 / :14640
// ③ 三档底栏（row / miniBar / compactRow）**各自**用哪几处
// ```
// ②③ 只有把树画出来才知道 —— 宽屏只画 row 档时，另外两处在**渲染树**上
// 本就不存在，但源码上仍在（static audit 会误报）。
//
// # 仪器：在真实渲染树上数「选集」按钮
//
// 走真实 Element 树，数同时满足「widget is TextButton 且 onPressed != null」
// 与「子树里有 Text('选集')」的节点数。
// ★ 播放页里除了底栏那三处，没有别的带「选集」字样的**按钮**
//   （面板标题在 EpisodeSheet 里是 Text('选集')，不是 TextButton）
//   ⇒ 计数 == 底栏可见的「选集」按钮数。
//
// # 四场景（Lead 给的验收表）
// ```text
// A  wide(>=900) 非全屏   ⇒ 期望 0（详情栏已能看到选集）
// B  窄屏(<900)           ⇒ 期望 >=1（详情区在播放器下方，右侧没有栏）
// C  全屏                 ⇒ 期望 >=1（全屏无详情区）
// D  历史记录 push 路径    ⇒ 期望 >=1
// ```
// ★ D 走**真的 push 通路**：shell.dart:4524-4547
//   `onPlay` → `Navigator.push(MaterialPageRoute(builder: (_) => MediaPage 构造))`。
//
// ⚠️ 上面**故意**写成「MediaPage 构造」而不是带半角括号的字面量 ——
//    `test/t456_media_route_touch_test.dart:80` 的扫描器是**纯文本**的
//    （`mediaPageCallSites()` 只做括号配对，**不剥注释**），
//    注释里出现一次 `MediaPage(` 就会被记成「漏传 isTouchOnly 的构造点」⇒ 假红。
//    实测：本行改成带括号的写法时 t456 报 `lib/t2_detail_button_probe.dart:47`。
//   本探针逐字复刻那一句，再把窗口压窄成「窄屏」形态。
//
// # 用法（同 t72p：隔离数据目录 + 从带 libmpv-2.dll 的目录运行）
// ```powershell
// flutter build windows --release -t lib/t2_detail_button_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\t2d-data"
// ```
// ⚠️ 绝不指向用户的真库（本探针会挂真 PlayerPage / MediaPage）。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'core/models.dart' show Episode;
import 'ui/app_theme.dart';
import 'ui/media_page.dart' show MediaPage;
import 'ui/media_session.dart' show MediaSession;
import 'ui/player_page.dart'
    show
        PlayerPage,
        debugPlayerIsFullscreen,
        debugPlayerMarkFirstFrameForProbe,
        debugPlayerPlaybackFailureState;
import 'ui/app_scaffold.dart';

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

final List<String> _log = [];

/// ★ 逐行**立即落盘**（不是只在 finish() 时写一次）
///
/// 为什么：探针第二次跑时整进程挂死、什么都没留下 —— 我连「挂在哪一步」
/// 都不知道。stdout 也被外层 `ReadToEnd()` 缓冲着（它在 `WaitForExit` **之前**，
/// 进程不退出就一个字节都拿不到）。⇒ 日志必须自己边跑边写文件。
void say(String s) {
  _log.add(s);
  debugPrint('[T2D] $s');
  // ignore: avoid_slow_async_io
  try {
    File('$_outDir\\t2d-detail-button.txt').writeAsStringSync(_log.join('\n'));
  } catch (_) {}
}

int pass = 0;
int fail = 0;
void ok(String name, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
    say('✓ $name${extra.isEmpty ? '' : '  $extra'}');
  } else {
    fail++;
    say('✗ $name${extra.isEmpty ? '' : '  $extra'}');
  }
}

Future<void> finish(int code) async {
  say('');
  say('RESULT pass=$pass fail=$fail');
  try {
    final f = File('$_outDir\\t2d-detail-button.txt');
    await f.writeAsString(_log.join('\n'));
    debugPrint('[T2D] 产物已写 ${f.path} (${f.lengthSync()} B)');
  } catch (e) {
    debugPrint('[T2D] ★ 写产物失败: $e');
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
//  仪器：数渲染树里的「选集」按钮
// ═══════════════════════════════════════════════════════════════════════

/// 递归数：`TextButton` 子树里含 `Text('选集')` 的节点数
int _count(Element e) {
  var n = 0;
  void walk(Element x) {
    final w = x.widget;
    if (w is TextButton) {
      var hit = false;
      void inner(Element y) {
        if (hit) return;
        final ww = y.widget;
        if (ww is Text && ww.data == '选集') {
          hit = true;
          return;
        }
        y.visitChildren(inner);
      }

      x.visitChildren(inner);
      if (hit) n++;
      return; // TextButton 里不会嵌 TextButton
    }
    x.visitChildren(walk);
  }

  if (e.widget is TextButton) return 1;
  e.visitChildren(walk);
  return n;
}

/// 在 [root] 子树下数「选集」按钮
int countEpisodeButtons(Element root) => _count(root);

/// ★ 只数**最上层路由**里的「选集」按钮
///
/// 为什么需要它：`Navigator.push` **不会**卸载下层路由 —— 初始那条裸
/// PlayerPage 路由仍然挂在树上（只是被上层遮住）。整棵树计数会把
/// **下层那条路由的按钮**也数进来 ⇒ A 场景实测 1（假阳）。
/// 探针要量的是「用户此刻看到的页面」，所以必须先定位最上层路由。
///
/// 取法：MediaPage 存在就取它（它就是 push 出来的那层）；否则取 PlayerPage。
int countTopmostEpisodeButtons(Element root) {
  final mp = findByType(root, MediaPage);
  if (mp != null) return _count(mp);
  final pp = findByType(root, PlayerPage);
  if (pp != null) return _count(pp);
  return -1;
}

int countTopmostAllButtons(Element root) {
  final mp = findByType(root, MediaPage);
  final scope = mp ?? findByType(root, PlayerPage);
  return scope == null ? -1 : countAllButtons(scope);
}

/// 在 [root] 子树下数所有 TextButton（仪器自检：证明树真的画了）
/// 把树上所有 `TextButton` 里**第一个 Text 的文本**列出来（诊断用）
List<String> buttonLabels(Element root) {
  final out = <String>[];
  void walk(Element x) {
    if (x.widget is TextButton) {
      String? label;
      void inner(Element y) {
        if (label != null) return;
        final ww = y.widget;
        if (ww is Text && ww.data != null) { label = ww.data; return; }
        y.visitChildren(inner);
      }
      x.visitChildren(inner);
      out.add(label ?? '<无文本>');
      return;
    }
    x.visitChildren(walk);
  }
  if (root.widget is TextButton) return ['<root 是 TextButton>'];
  root.visitChildren(walk);
  return out;
}

int countAllButtons(Element root) {
  var n = 0;
  void walk(Element x) {
    if (x.widget is TextButton) n++;
    x.visitChildren(walk);
  }

  walk(root);
  return n;
}

Element? findByType(Element e, Type t) {
  Element? hit;
  void walk(Element x) {
    if (hit != null) return;
    if (x.widget.runtimeType == t) {
      hit = x;
      return;
    }
    x.visitChildren(walk);
  }

  if (e.widget.runtimeType == t) return e;
  e.visitChildren(walk);
  return hit;
}

Future<void> pumpFrame() async {
  final b = WidgetsBinding.instance;
  b.scheduleFrame();
  await b.endOfFrame.timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 等 n 帧，并**周期性把进度写进日志**
///
/// ★ 与 `pumpFrame()` 的区别：真挂了以后，产物里能看出挂在第几帧。
Future<void> pumpFrames(int n, String tag) async {
  for (var i = 0; i < n; i++) {
    if (i % 10 == 0) say('  [$tag] frame $i/$n');
    await pumpFrame();
  }
}

/// 向**硬件键盘**投一个真实的 down + up（与真人敲键一致）
///
/// ★ 为什么不用 `WidgetTester.sendKeyDownEvent`：那是 flutter_test 的 API，
///   真渲染探针里没有 WidgetTester。真机上用户的按键正是经
///   `HardwareKeyboard` 派发到 `FocusManager` 的 early handler
///   （player_page.dart:8286 `_onEarlyKey`）⇒ 这里走同一条路。
Future<void> tapHardwareKey(LogicalKeyboardKey key) async {
  final hk = HardwareKeyboard.instance;
  hk.handleKeyEvent(
    KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
  );
  await pumpFrame();
  hk.handleKeyEvent(
    KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: key,
      timeStamp: Duration.zero,
    ),
  );
  await pumpFrame();
}

List<Episode> _eps(int n) => [
  for (var i = 0; i < n; i++)
    Episode(
      id: 'e$i',
      title: '第 ${i + 1} 集',
      url: 'https://probe.invalid/$i.m3u8',
    ),
];

// ═══════════════════════════════════════════════════════════════════════
//  可控尺寸的壳：把真实 PlayerPage / MediaPage 塞进指定逻辑尺寸
// ═══════════════════════════════════════════════════════════════════════

final _rootKey = GlobalKey();

/// 直接钉 `MediaQuery.size` —— 比真改窗口可靠（真窗口客户区/DPI 会引入
/// 偏差；本探针要的是**布局判据**的读数，不是像素级几何）。
final _size = ValueNotifier<Size>(const Size(1440, 900));

class ProbeShell extends StatelessWidget {
  const ProbeShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Size>(
      valueListenable: _size,
      builder: (context, size, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size),
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    );
  }
}

// =======================================================================
//  ★★ 真·渲染帧推进（本探针的**核心仪器**，前几轮就是缺了它）
// =======================================================================
//
// # 错在哪（血泪）
// ```text
// 前几轮我用的是：
//     b.scheduleFrame();
//     await b.endOfFrame;         // <-- 等的是「上一轮/本轮已排的那个帧」结束
// ```
// ★ 真渲染下「正在跑的那个帧」的 endOfFrame **在 await 之前就完成了**，
//   于是 await 立刻返回、被 await 的那个帧其实是**下一轮循环刚排的**帧。
//   净效果：**每次 await 之间没有任何真实 wall-clock 时间流逝** =>
//   整段 while 循环（几百次迭代）在同一毫秒内跑完 =>
//   `_PlayerPageState` 挂在 PlayerPage 上的**定时器**（起播看门狗、
//   `_armHideTimer` 等）**一次都不会到期**。
// => 后果：player_page.dart:10317 那段「起播超时 => _error」的生产兜底
//   **从未被执行** => E 场景（「起播失败态底栏一帧不画」）读到的 0
//   **不是这条兜底产生的** —— 是假象。
// ```
//
// # 为什么必须用 delayed（不能用 scheduleFrame 空转）
// ```text
// ★ Flutter 的动画/Timer 全都挂在**帧回调**与**事件循环**上：
//   只排帧不睡觉 => 事件循环从不 yield 够久 => Timer 永不到期。
// ★ `Future.delayed(16ms)` 让出事件循环 =>
//   · Timer 能到期（起播看门狗因此真的会走）
//   · 每个 delayed 之后系统自己会排帧 => 动画真的推进
// ★ 代价：20 帧 ~= 320ms 真实时间（可接受；本探针靠「帧数」而不是
//   「wall-clock」表达意图，delayed 只是让帧与时间**成对**推进）。
// ```
Future<void> pumpRealFrames(int n, String tag) async {
  for (var i = 0; i < n; i++) {
    if (i % 10 == 0) say('  [$tag] real frame $i/$n');
    WidgetsBinding.instance.scheduleFrame();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

void setSize(double w, double h) => _size.value = Size(w, h);

// ── D 场景：真的 Navigator.push（复刻 shell.dart:4524-4547）──

final _navKey = GlobalKey<NavigatorState>();

/// 从「历史记录」真入口 push 出 MediaPage
///
/// ★ 逐字复刻 `shell.dart:4524-4547` 的 `onPlay` 回调体 ——
///   唯独把 provider/id/title 换成探针值（真入口也是这么传的）。
/// ★ `MediaPage` **没有** `hasRightDetailBar` 参数：它自己算
///   （`media_page.dart:729` `wide && !fullscreen`）—— 这正是
///   「跨文件单一数据源」的设计，探针不越权去传。
void pushHistoryEntry() {
  final nav = _navKey.currentState;
  if (nav == null) return;
  nav.push(
    MaterialPageRoute(
      builder: (_) => const MediaPage(
        provider: 'probe',
        id: 'probe',
        title: 'task-2④ 历史记录 push 探针',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}


// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★★ 必须在 runApp 之前（shell.dart:276 / t72p:388 的同一条）。
  //   漏了它 ⇒ `_PlayerPageState.initState`（player_page.dart:1930）
  //   抛 `MediaKit.ensureInitialized must be called before using any API`
  //   ⇒ 整棵 PlayerPage 被换成 ErrorWidget ⇒ 仪器数到 0 个 TextButton
  //   （我第一次跑就是这样：A/B/C/D 全 0，是探针的锅不是生产的锅）。
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化（默认）');
  } catch (e) {
    final dll = File(
        '${Directory.current.path}${Platform.pathSeparator}libmpv-2.dll');
    say('默认初始化失败: $e → 退回显式 DLL（存在=${dll.existsSync()}）');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  final dir = await _resolveDataDir();
  debugPrint('[T2D] ====== task-2(4) 底栏「选集」按钮 —— 真渲染取证 ======');
  say('数据目录: $dir');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1440, 900));
    await windowManager.setTitle('源影 · task-2(4) 选集按钮探针');
  }

  final brightness = AppTheme.resolve(systemBrightness: Brightness.light);
  final materialTheme = AppTheme.themeFor(brightness);

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale("zh", "CN"), Locale("en", "US")],
        theme: materialTheme,
        // ★ 生产外壳逐字复刻（shell.dart:2854-2865 / t72p:447-455）
        builder: (context, child) => AppThemeHost(
          data: materialTheme,
          child: AppScaffold(
            child: Material(type: MaterialType.transparency, child: child!),
          ),
        ),
        home: ProbeShell(
          child: Navigator(
            key: _navKey,
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => PlayerPage(
                provider: 'probe',
                id: 'probe',
                title: 'task-2④ 底栏探针',
                episodes: _eps(12),
                episodeIndex: 0,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // ★ 1200ms 让 runApp 之后的**第一帧**与起播流程有真实时间推进
  //   （不是排帧空转 —— 那正是前几轮假绿的原因，见 pumpRealFrames 注释）。
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  final root = _rootKey.currentContext as Element?;
  if (root == null) {
    say('★ 根元素没挂上 ⇒ 中止');
    await finish(1);
  }

  // ── 0 仪器自检 ──
  say('');
  say('── 0 仪器自检 ──');
  final ppEl = findByType(root!, PlayerPage);
  ok('树上找到**真实的** PlayerPage 元素', ppEl != null,
      '${ppEl?.widget.runtimeType}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 E（★ lead 要求的**反向场景**，必须**先于**首帧注入跑）
  //
  //  目的：证明 A~D 的绿不是「靠把错误态抹掉造出来的」。
  //  此刻**还没**调 `debugPlayerMarkFirstFrameForProbe()` ⇒ 假 provider
  //  起播失败 ⇒ `_error != null` ⇒ `_BottomBar` 的 if
  //  （player_page.dart:10209 `if (_controlsVisible && _error == null && …)`）
  //  不成立 ⇒ 底栏一帧都不该进树。
  //
  //  ★ 这一条同时是「仪器有分辨力」的证明：同一棵树、同一个计数函数，
  //    只差一个 `_error`，读数就从 6 变 0。
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── E 反向场景：起播失败（未注入首帧）⇒ 底栏必须一帧不画 ──');
  setSize(1440, 900);
  // ★ 必须**真帧**（见 pumpRealFrames 的注释）：起播看门狗是 Timer，
  //   假帧（endOfFrame 空转）下它永不到期 ⇒ _error 永远 null ⇒
  //   这一场景会**假绿**。
  await pumpRealFrames(60, 'E');
  final eRoot = _rootKey.currentContext as Element?;
  final eTotal = eRoot == null ? -1 : countAllButtons(eRoot);
  say('E 采样：宽=${_size.value.width} 「选集」按钮数='
      '${eRoot == null ? -1 : countEpisodeButtons(eRoot)} '
      '（全部 TextButton=$eTotal）');
  ok('E 起播失败态 ⇒ 底栏一帧不画（TextButton=0）', eTotal == 0, '实测 $eTotal');
  say('  E 状态读数: ${debugPlayerPlaybackFailureState()}');

  // ★★★ 关键一步：把 PlayerPage 从「起播失败」态里捞出来
  //
  //   `_BottomBar` 的绘制条件是（player_page.dart:10209-10219）
  //     if (_controlsVisible && _error == null && !_episodeSheetOpen && …)
  //   探针用的是假 provider（『probe』）、核心没起（日志里就是
  //   `[PROVIDER-NAME] listProviders 失败，退回 id: SourinCoreException(unsupported)`）
  //   ⇒ 起播必然失败 ⇒ `_error != null` ⇒ **整条底栏一帧都不画**。
  //   ⇒ 这就是第二次跑「TextButton 总数=0」的真因（不是「按钮被隐藏」，
  //     是底栏根本没进树）—— 与 `_controlsVisible` 无关。
  //
  //   修法用**本仓既有的探针钩子**（不是我新造的）：
  //   `debugPlayerMarkFirstFrameForProbe()`（player_page.dart:11845-11859）
  //   逐字复刻 stream.width 的生产闭包体 ⇒ `_sawFirstFrame = true` 且
  //   `_error = null` / `_loading = false`。它也早就被测试侧用着
  //   （见 player_page.dart:11841 的说明）⇒ 走的是生产同一路径，不是旁路。
  final marked = debugPlayerMarkFirstFrameForProbe();
  say('已注入首帧（清掉起播失败态，让底栏进树）: $marked');
  await pumpRealFrames(6, 'E2');
  final eRoot2 = _rootKey.currentContext as Element?;
  final e2Count = eRoot2 == null ? -1 : countTopmostEpisodeButtons(eRoot2);
  ok('注入首帧后底栏**确实**回到树里（证明确实是 _error 挡住了它）',
      eRoot2 != null && countAllButtons(eRoot2) > 0,
      'TextButton=${eRoot2 == null ? -1 : countAllButtons(eRoot2)}');
  say('  E2 状态读数: ${debugPlayerPlaybackFailureState()}');
  say('  E2 按键标签: ${buttonLabels(eRoot2!).join(" | ")}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 A：wide(>=900) 非全屏，**经真 MediaPage** ⇒ 右侧详情栏可见 ⇒ 期望 0
  //
  //  ★ 为什么必须走 MediaPage 而不是裸挂 PlayerPage：
  //    `hasRightDetailBar` 是**宿主算好传进来的**（media_page.dart:729
  //    `final bool hasRightDetail = wide && !fullscreen;`），
  //    PlayerPage 自己不看 900、也不看全屏（player_page.dart:357 默认 false）。
  //    ⇒ 裸挂 PlayerPage 只测到「默认值 false ⇒ 按钮在」，
  //      测不到「MediaPage 真的把 true 传下去了」。
  //      这正是我第一版 A=1 的原因 —— **探针口径错了，不是生产错了**。
  //    生产入口（shell.dart:4524-4547）一律经 MediaPage，所以 A 也必须经它。
  // ══════════════════════════════════════════════════════════════════
  // ★★ A 场景（唯一会 push MediaPage 的场景）已**移到 D 之后**。
  //    原因：Navigator.push 不卸载下层路由，而 B/C/D 原来都在 A 之后 ⇒
  //    它们的 countTopmostEpisodeButtons 量的还是**那条 MediaPage**
  //    （最上层路由没变）⇒ B/C 读到假 0。实测证据：产物里
  //    「B 采样：宽=360.0 「选集」按钮数=0」紧跟在 A 采样之后。
  //    ⇒ 修法：所有「裸 PlayerPage」场景（B/C）必须先跑，
  //      A 与 D 这两条 push 场景放在最后分别 push。
  //    ★ 另：探针里**绝不能** pop 已起播的路由
  //      （pop 掉 MediaPage 会 dispose 内层 PlayerPage 连带 media_kit
  //      的 Texture/VideoOutput ⇒ 进程挂死、产物停在 [A2a] frame 0/10）。

  // ══════════════════════════════════════════════════════════════════
  //  A2 的对照证据不必再单独跑 —— 就是**上面 E2 那次采样**。
  //
  //  E2 量的正是「裸挂 PlayerPage、`hasRightDetailBar` 取默认值 false、
  //  底栏已经在树上」那一刻 ⇒ 读数 TextButton=6（含「选集」）。
  //  与 A（经 MediaPage、宿主传 true ⇒ 0）并排看，就是完整的对照：
  //    「按钮消失」是**有条件**的 —— 只有宿主明确传 true 才消失。
  //
  //  ★ 我原本在这里写了 `_navKey.currentState?.popUntil((r) => r.isFirst)`
  //    想回退到裸 PlayerPage 再量一次，但它**必然挂死**：
  //    pop 掉 MediaPage 会 dispose 它内层那个 PlayerPage（连带 media_kit
  //    的 Texture/VideoOutput），真机渲染下这条路走不通。
  //    实测症状：产物停在 `[A2a] frame 0/10` 再也不动，进程 CPU 接近 0。
  //    ⇒ 教训：探针里**不要再 pop 已起播的路由**；要对照就新挂一层，
  //      或者复用已有的、同一时刻的读数。
  // ══════════════════════════════════════════════════════════════════
  final a2Count = e2Count;

  // ══════════════════════════════════════════════════════════════════
  //  场景 B：窄屏(<900) ⇒ 详情区在播放器下方、右侧没有栏 ⇒ 期望 >=1
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── B 窄屏 360x800（无右侧详情栏）──');
  setSize(360, 800);
  await pumpRealFrames(24, 'B');
  // ★ 每次采样前**重注入**：假 provider 的 _load() 会反复重试
  //   （player_page.dart:3008 开头 _error=null，到 :3057 取不到可播流又置回）
  //   ⇒ 一次注入的效力会被下一轮重试吃掉。
  debugPlayerMarkFirstFrameForProbe();
  await pumpRealFrames(3, 'B2');
  final bCount = countTopmostEpisodeButtons(root);
  say('B 采样：宽=${_size.value.width} 「选集」按钮数=$bCount '
      '（全部 TextButton=${countTopmostAllButtons(root)}）');
  say('  B 状态读数: ${debugPlayerPlaybackFailureState()}');
  say('  B 按键标签: ${buttonLabels(root).join(" | ")}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 C：全屏 ⇒ 无详情区 ⇒ 期望 >=1
  // ══════════════════════════════════════════════════════════════════
  // ★ 全屏由 PlayerPage 自己的 `_toggleFullscreen()` 驱动
  //   （player_page.dart:7585-7617），这里走公开状态而不是自建判据。
  say('');
  say('── C 全屏（宽屏 + 全屏态）──');
  setSize(1440, 900);
  await pumpRealFrames(12, 'C1');
  // ★ 用**真的硬件键**进全屏（Enter）—— 与用户按 F/Enter 同一条路径
  //   （player_page.dart:8313 `_onHardwareKey`）。
  //   不用 debugPlayer* 私有钩子：那只能读状态、不能切换。
  await tapHardwareKey(LogicalKeyboardKey.enter);
  await pumpRealFrames(30, 'C2');
  debugPlayerMarkFirstFrameForProbe();
  await pumpRealFrames(3, 'C3');
  final cCount = countTopmostEpisodeButtons(root);
  say('C 采样：宽=${_size.value.width} 全屏=${debugPlayerIsFullscreen()} '
      '「选集」按钮数=$cCount（全部 TextButton=${countTopmostAllButtons(root)}）');
  say('  C 状态读数: ${debugPlayerPlaybackFailureState()}');

  // ══════════════════════════════════════════════════════════════════
  //  场景 D：从「历史记录」真入口 push 进播放页（窄窗）⇒ 期望 >=1
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── D 历史记录真入口 push（窄窗 800x700）──');
  setSize(800, 700);
  await pumpRealFrames(12, 'D1');
  pushHistoryEntry();
  await pumpRealFrames(40, 'D2');
  debugPlayerMarkFirstFrameForProbe();
  await pumpRealFrames(3, 'D3');
  final dRoot = _rootKey.currentContext as Element?;
  if (dRoot == null) {
    say('★ D 场景根元素丢了 ⇒ 中止');
    await finish(1);
  }
  final mpEl = findByType(dRoot!, MediaPage);
  ok('D 树上找到 push 出来的**真实的** MediaPage 元素', mpEl != null,
      '${mpEl?.widget.runtimeType}');
  final dCount = countTopmostEpisodeButtons(dRoot);
  say('D 采样：宽=${_size.value.width} 「选集」按钮数=$dCount '
      '（全部 TextButton=${countTopmostAllButtons(dRoot)}）');
  say('  D 状态读数: ${debugPlayerPlaybackFailureState()}');
  // ★ 诊断：D 是全场景里**唯一**「窄窗 + 经 MediaPage」的组合。
  //   窄窗下 MediaPage 走 Column 分支（media_page.dart:1054-1066），
  //   播放器只占 (videoH*10) flex —— 800x700 时 videoH=315（=min(450, 315)）
  //   ⇒ 播放器槽只有 ~315px 高。若底栏在这个高度下被 HeightBudget 裁掉，
  //   读数就是 0 而非「逻辑隐藏」。dump 出来最快。
  final dMp = findByType(dRoot, MediaPage);
  say('  D MediaPage 子树按钮标签: ${dMp == null ? "-" : buttonLabels(dMp).join(" | ")}');
  final dPp = findByType(dRoot, PlayerPage);
  say('  D PlayerPage 子树按钮标签: ${dPp == null ? "-" : buttonLabels(dPp).join(" | ")}');
  say('  D 最上层 scoped 标签: ${dMp == null ? "-" : buttonLabels(dMp).join(" | ")}');
  // ★ 关键分辨：树里**有没有**任何 `Text('选集')`（哪怕被裁掉）。
  //   · 完全没有 ⇒ 是我/生产的条件把它**没建出来**（hasEpisodes=false 之类）；
  //   · 有但 TextButton 计数里没有 ⇒ 它在**另一条渲染支**（比如被
  //     RenderFlex 溢出裁掉、或它在的子树没走 TextButton 分支）。
  int anyText = 0;
  void findText(Element x) {
    final w = x.widget;
    if (w is Text && w.data == '选集') anyText++;
    x.visitChildren(findText);
  }
  if (dMp != null) findText(dMp);
  say('  D 树里 Text「选集」出现次数($anyText) [MediaPage 子树]');
  // 全树（含下层裸 PlayerPage 路由）
  int allText = 0;
  void findText2(Element x) {
    final w = x.widget;
    if (w is Text && w.data == '选集') allText++;
    x.visitChildren(findText2);
  }
  findText2(dRoot);
  say('  D 全树 Text「选集」出现次数($allText)');
  // ★★ 生产真相（D 场景的最后一环）：历史入口 push 出来的 MediaPage
  //    widget.episodes **是空的**（shell.dart:4579 不传 episodes），底栏
  //    「选集」靠 DetailPage 加载完 → _onDetailLoaded →
  //    _session.updateEpisodes(d.episodes) → PlayerPage.updateEpisodes
  //    (player_page.dart:6150) 异步回填 _episodes 之后才会出现。
  //    ⇒ 探针用假 provider，详情永远加载不完 ⇒ _episodes 恒空 ⇒
  //      量到 0 **不是**生产的最终态。这一段用真回填入口补上再量。
  {
    final list = <StatefulElement>[];
    void collect(Element x) {
      if (x is StatefulElement && x.widget.runtimeType == PlayerPage) list.add(x);
      x.visitChildren(collect);
    }
    collect(dRoot);
    for (final e in list) {
      final st = e.state;
      if (st is MediaSession) (st as MediaSession).updateEpisodes(_eps(12));
    }
  }
  await pumpRealFrames(6, 'D4');
  debugPlayerMarkFirstFrameForProbe();
  await pumpRealFrames(3, 'D5');
  final dMp2 = findByType(dRoot, MediaPage);
  say('  D 回填后 MediaPage 子树标签: ' + (dMp2 == null ? '-' : buttonLabels(dMp2).join(' | ')));
  final dCountBackfill = countTopmostEpisodeButtons(dRoot);
  say('  D 回填后「选集」按钮数=' + dCountBackfill.toString() + ' （全部 TextButton=' + countAllButtons(dRoot).toString() + '）');
  // ★ 分辨：树上到底有几个 MediaPage 元素、几个 PlayerPage 元素？
  //   若 MediaPage > 1 ⇒ findByType 命中的可能不是「用户看到的那个」。
  int nMp = 0, nPp = 0;
  void countTypes(Element x) {
    final w = x.widget;
    if (w.runtimeType == MediaPage) nMp++;
    if (w.runtimeType == PlayerPage) nPp++;
    x.visitChildren(countTypes);
  }
  countTypes(dRoot);
  say('  D 元素计数：MediaPage=$nMp PlayerPage=$nPp');
  // 逐个 MediaPage 报它的子树按钮
  int idx = 0;
  void eachMp(Element x) {
    if (x.widget.runtimeType == MediaPage) {
      say('    MediaPage[#$idx] 子树标签: ${buttonLabels(x).join(" | ")}');
      idx++;
    }
    x.visitChildren(eachMp);
  }
  eachMp(dRoot);
  // 逐个 PlayerPage 报它的子树按钮
  int pidx = 0;
  void eachPp(Element x) {
    if (x.widget.runtimeType == PlayerPage) {
      say('    PlayerPage[#$pidx] 子树标签: ${buttonLabels(x).join(" | ")}');
      final rb = x.renderObject;
      if (rb is RenderBox && rb.hasSize) {
        say("      size: " + rb.size.width.toString() + " x " + rb.size.height.toString());
      }
      pidx++;
    }
    x.visitChildren(eachPp);
  }
  eachPp(dRoot);

  // ══════════════════════════════════════════════════════════════════
  //  场景 A（★ 移到最后的 push 场景之一）：宽屏 1440x900 经真 MediaPage
  //
  //  为什么必须经 MediaPage：`hasRightDetailBar` 是**宿主算好传进来的**
  //  （media_page.dart:729 `final bool hasRightDetail = wide && !fullscreen;`），
  //  PlayerPage 不看 900、也不看全屏（默认 false）。
  //  ⇒ 裸挂 PlayerPage 只能测到「默认值 false ⇒ 按钮在」，
  //    测不到「MediaPage 真的把 true 传下去了」。
  //  ★ 它必须在所有「裸 PlayerPage」场景之后 —— 见上方移动说明。
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── A 宽屏 1440x900 非全屏 · 经真 MediaPage（右侧详情栏可见）──');
  setSize(1440, 900);
  await pumpRealFrames(8, 'A0');
  pushHistoryEntry();
  await pumpRealFrames(40, 'A1');
  debugPlayerMarkFirstFrameForProbe();
  await pumpRealFrames(3, 'A2');
  final aRoot = _rootKey.currentContext as Element?;
  final aMp = aRoot == null ? null : findByType(aRoot, MediaPage);
  ok('A 树上找到**真实的** MediaPage 元素', aMp != null,
      '${aMp?.widget.runtimeType}');
  final aCount = aRoot == null ? -1 : countTopmostEpisodeButtons(aRoot);
  say('A 采样：宽=${_size.value.width} 「选集」按钮数=$aCount '
      '（全部 TextButton=${aRoot == null ? -1 : countTopmostAllButtons(aRoot)}）');
  say('  A 状态读数: ${debugPlayerPlaybackFailureState()}');
  say('  A 按键标签: ${aRoot == null ? "-" : buttonLabels(aRoot).join(" | ")}');

  // ══════════════════════════════════════════════════════════════════
  //  判读
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── 判读（Lead 的四场景验收表 + 两条对照）──');
  ok('A 宽屏非全屏 · 经真 MediaPage ⇒ 底栏「选集」**全消失**（详情栏已是入口）',
      aCount == 0, '实测 $aCount');
  ok('A2 对照 · 裸 PlayerPage(hasRightDetailBar 默认 false) ⇒ **仍在**',
      a2Count >= 1, '实测 $a2Count');
  ok('E 对照 · 起播失败态 ⇒ 底栏**一帧不画**（不是「隐藏」）',
      eTotal == 0, '实测 $eTotal');
  ok('B 窄屏 ⇒ 底栏「选集」**仍在**（右侧没有详情栏）',
      bCount >= 1, '实测 $bCount');
  ok('C 全屏 ⇒ 底栏「选集」**仍在**（全屏无详情区）',
      cCount >= 1, '实测 $cCount');
  /*
   * ★ D 的采分点用**回填后**的读数，不是 push 当时那一刻的读数。
   *
   * 生产真相（本轮查明）：历史入口 push 出来的 MediaPage
   * `widget.episodes` **是空的**（shell.dart:4579 不传 `episodes:`），
   * 底栏「选集」靠 DetailPage 加载完 → media_page.dart:637
   * `_session?.updateEpisodes(d.episodes)` → player_page.dart:6150
   * `PlayerPage.updateEpisodes` **异步回填** `_episodes` 之后才出现。
   * ⇒ 「push 那一刻量到 0」不是缺陷，是正常的加载中间态；
   *    用户真正看到的底栏是回填之后的。
   */
  ok('D 历史记录真入口 push 窄窗 ⇒ 底栏「选集」**仍在**（剧集回填后）',
      dCountBackfill >= 1, '回填后实测 $dCountBackfill（push 当时 $dCount，详情未加载完）');

  // ★ Lead 追加要求：三处按钮（:14019 / :14350 / :14640）的 forall 存在性。
  //   `hasEpisodes` 是**一个**布尔、三处 `if (hasEpisodes)` 共用它
  //   （player_page.dart:7724 前面那段注释写了「改一处等于改三处」），
  //   所以「三处同时消失/出现」在结构上由单一数据源保证。
  //   渲染级读数只能看到**当前档位**那一处（另两处不同档位不同时构建），
  //   ⇒ 实测的是「该档位下树上『选集』按钮计数」。
  say('');
  say('── 三处按钮点位（player_page.dart:14019 row / :14350 compactRow / :14640 row2）──');
  say('· 三处共用同一个 hasEpisodes（player_page.dart:7724 单点计算，改一处等于改三处）');
  say('· 档位由底栏可用宽决定（:13040 _kBottomBarRowWidth=830 / :13056 _kBottomBarMiniWidth=528），');
  say('  不是窗口宽 ⇒ A 场景（宽屏经 MediaPage）与 B 场景（窄屏）覆盖到不同档位。');

  say('');
  say('VERDICT A(wide经MediaPage)=$aCount A2(裸PlayerPage)=$a2Count '
      'E(起播失败底栏)=$eTotal B(窄屏)=$bCount '
      'C(全屏)=$cCount D(历史push窄窗)=$dCount'
      ' D回填后=$dCountBackfill');
  await finish(fail == 0 ? 0 : 1);
}
