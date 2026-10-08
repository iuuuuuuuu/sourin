// ═══════════════════════════════════════════════════════════════════════
//  task-72【④】「播放页面感觉也卡卡的」—— 改前 / 改后 **量化**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么是这三个候选（不是"读码觉得卡"）
// ```text
// A  `_showControls()` 无条件 setState      ← 由 MouseRegion.onHover 包整页触发
// B  `position.listen` 每 tick setState     ← mpv 的 time-pos 原样转发，无节流
// C  build 内无条件 `_liveChannels()`       ← 抽屉关着也现取频道列表
// D  hwdec = d3d11va-copy（copy-back）      ← 配置项，只能真机量（不在本文件）
// ```
//
// # 仪器（与改前探针**同一台**，读数才可逐字对比）
// ```text
// Flutter SDK `widgets/framework.dart:5515-5532`：`Element.rebuild()` 里
//     assert(() { debugOnRebuildDirtyWidget?.call(this, _debugBuiltOnce); ... }());
// ⇒ 每个 dirty 元素每次重建回调一次。
//   · `e.widget is PlayerPage` 的元素每次重建 = 调了一次
//     `_PlayerPageState.build`（`player_page.dart` 里 884 行那个）
//   · 回调总数 = 这一帧真正重建的元素总数（"重建面"）
// ```
//
// # ★★★ 改前读数（`.probe/probe_tests/t72_jank_probe_test.dart`，同一台仪器）
// ```text
// PA   60 次鼠标移动（每次 2px）⇒ PlayerPage 重建 **60** 次 / 元素 9960 次
// PA2  30 次**同坐标** hover    ⇒ 重建 **30** 次
// PC   60 次整页重建            ⇒ `onLiveChannels()` 被调 **60** 次（1:1）
// PB   ✗ 未测出（真播放的 open() 在 widget 测试里挂到 10 分钟超时）
//      ⇒ 本文件用 `debugPlayerPushPositionForProbe` 走**真实处理路径**
//        灌 tick，把 B 变成读数（不依赖真播放）
// ```
//
// # 反自欺（task-55 立的规矩：假阳性比假阴性更危险）
// ```text
// ① 阴性对照：装好仪器、pump 一帧而**不改**任何状态 ⇒ 必须 0。
// ② 阳性对照：调一个**确定**会 setState 的钩子 ⇒ 必须 >=1。
// 两条都过，后面的数字才算数。
// ```
//
// ⚠️ 只打印事实 + 断言；不打印结论。

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ── 计数仪器 ──────────────────────────────────────────────────────────
int _page = 0; // _PlayerPageState.build 被调用次数
int _all = 0; // 所有元素重建次数之和

void _install() {
  _page = 0;
  _all = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (e.widget is PlayerPage) _page++;
  };
}

void _uninstall() => debugOnRebuildDirtyWidget = null;

// ── 挂载 ──────────────────────────────────────────────────────────────
List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t, {void Function()? onLiveChannels}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '卡顿测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        onLiveChannels: onLiveChannels == null
            ? null
            : () {
                onLiveChannels();
                return (
                  channels: const <LiveChannel>[
                    LiveChannel(id: 'c1', name: 'CCTV-1', group: '央视'),
                    LiveChannel(id: 'c2', name: 'CCTV-2', group: '央视'),
                  ],
                  index: 0,
                );
              },
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  // ★ 落定：挂载那一帧的收尾工作（`_load()` 的 postFrame 等）先跑完，
  //   否则它会混进后面的计数里，把"改前/改后"都污染成同一个数。
  await t.pump();
  await t.pump();
}

// ══════════════════════════════════════════════════════════════════════════
//  libmpv 夹具：跨平台探测 + 缺夹具时**跳过**（不是假红）
// ══════════════════════════════════════════════════════════════════════════
//
// ★ 为什么必须给**显式路径**：`media_kit` 的
//   `NativeLibrary.ensureInitialized()` 只按**默认名**搜系统路径 ——
//   Windows 找 `libmpv-2.dll`、macOS 找 `Mpv.framework/Mpv`
//   （`media_kit-1.2.6/lib/src/player/native/core/native_library.dart:49-69`）
//   —— 而 `flutter test` 的进程里两者都**不在**搜索路径上 ⇒ 不传路径
//   就是 `Cannot find libmpv-2.dll in your system %PATH%`。
//
// ★ 为什么是**两套**路径：libmpv 由 media_kit 的 libs 包在**构建期**下载，
//   两端落点不同：
//     · Windows：CMake 下到 `build/windows/x64/libmpv/libmpv-2.dll`
//     · macOS  ：Makefile 下 `Mpv.xcframework`，构建后进 app 包的
//                `Contents/Frameworks/libmpv-2.dylib`
//   ⇒ 只认 Windows 那条路径的话，macOS 上永远探不到（即使夹具真的在）。
//
// ★ 为什么缺夹具是 **skip** 而不是 fail：`build/` 被 `.gitignore:36`
//   忽略、从不入库，而 CI 的 `flutter test` 排在
//   `flutter build windows|macos` **之前** ⇒ 没跑过构建的机器上夹具
//   **必然缺席**。那是环境前提，不是本文件的缺陷。
//
// ⚠️ 不是「放宽断言」：夹具在的机器上（例如本地跑过
//   `flutter build windows`）下面的断言一条都不会少跑。
// ⚠️ **不能**改成 `@Tags(['native-media'])`：`dart_test.yaml` 把该标签
//   默认 skip ⇒ 本文件的 ★★★ 契约守卫会从默认套件里**整个消失**
//   —— 那是移除覆盖，不是加守卫。
//
// ★ 本文件 **5 条**用例全都挂 `PlayerPage` ⇒ 全都依赖播放器。
// ══════════════════════════════════════════════════════════════════════════

/// libmpv 的候选路径（**跨平台** —— 别只写 Windows 那一条）
List<String> _libmpvCandidates() {
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    final out = <String>[
      // pod 的 vendored framework（`pod install` 之后）
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
    // `flutter build macos` 之后 libmpv 就在 app 包里
    // （★ app 名不一定是 `sourin_spike` —— 发布版是中文「源影」⇒ 扫目录）
    for (final cfg in const <String>['Release', 'Debug', 'Profile']) {
      final dir = Directory('build/macos/Build/Products/$cfg');
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is Directory && e.path.endsWith('.app')) {
          out.add('${e.path}/Contents/Frameworks/libmpv-2.dylib');
        }
      }
    }
    return out;
  }
  // Linux / 其它：libmpv 由系统包管理器提供
  return <String>[
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
  ];
}

/// 探测到的 libmpv **绝对**路径；`null` = 夹具缺失
String? _libmpv;

/// 夹具准备（`setUpAll` 用）：探到就初始化 MediaKit，探不到**什么都不做**。
///
/// ⚠️ 探不到时这里**绝不 fail** —— 理由见文件头；守卫下沉到
///   `_requireLibmpv()`，由每个**依赖播放器**的用例自己调。
void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[LIBMPV] 夹具 = $_libmpv');
      return;
    }
  }
  // ignore: avoid_print
  print('[LIBMPV] 夹具**缺失** ⇒ 依赖播放器的用例将 markTestSkipped；'
      '候选 = ${_libmpvCandidates()}');
}

/// 依赖播放器的用例开头调用：`if (!_requireLibmpv()) return;`
///
/// 返回 `true` = 夹具就绪可继续；`false` = **已标记跳过，调用方必须 return**
/// （`markTestSkipped` 只打标记，**不会**中断当前函数 —— 本地实测：标记之后
/// 的代码照常执行，所以必须紧跟 `return`）。
bool _requireLibmpv() {
  if (_libmpv != null) return true;
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来，本条无从断言。'
      '手动跑：先 `flutter build windows`（或 macOS 上 `flutter build macos`）'
      '；候选路径 = ${_libmpvCandidates()}');
  return false;
}

void main() {
  setUpAll(_prepareLibmpvFixture);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    _uninstall();
    RemoteBridge.instance.stop();
  });

  // ═══ 仪器自检 ════════════════════════════════════════════════════════
  testWidgets('P0 仪器自检：阴性对照 0/0 + 阳性对照 >=1', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    _install();
    await t.pump();
    print('P0|阴性对照 pump(无状态变化) => page=$_page all=$_all');
    expect(_page, 0, reason: '静置帧不该重建整页 —— 不为 0 说明仪器或页面有问题');
    expect(_all, 0, reason: '静置帧不该有任何元素重建');

    _install();
    final ok = debugPlayerOpenHintsForProbe();
    await t.pump();
    print('P0|阳性对照 openHints(ok=$ok) => page=$_page all=$_all');
    expect(ok, isTrue, reason: '钩子本身要生效，否则下面的断言是空的');
    expect(_page, greaterThanOrEqualTo(1),
        reason: '阳性对照必须 >=1 —— 否则仪器没有区分力（铁律：一条永远为真的断言比没有断言更危险）');
  });

  // ═══ 候选 A：hover 不再整页重建 ══════════════════════════════════════
  testWidgets('PA 控制条已可见时，60 次鼠标移动 ⇒ 0 次整页重建', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    // 先建立 device state（首帧让 MouseTracker 认识这个指针）
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    const moves = 60;
    _install();
    for (var i = 0; i < moves; i++) {
      await t.sendEventToBinding(p.hover(Offset(200.0 + i * 2, 400)));
      await t.pump();
    }
    print('PA|$moves 次鼠标移动 => PlayerPage 重建 $_page 次 / 元素重建 $_all 次'
        '（改前：page=60 / all=9960）');
    expect(_page, 0,
        reason: '`_controlsVisible` 初值就是 true（player_page.dart:487）'
            '⇒ hover 时值没变，不该重建整页。'
            '不为 0 ⇒ `_showControls()` 的值守卫被去掉了（改前这里是 60）');
  });

  // ═══ 候选 B：位置 tick 只在"显示的那一秒"变化时重建 ══════════════════
  testWidgets('PB 180 次位置 tick（跨 3 秒）⇒ 3 次整页重建', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    // ★ 走**生产代码自己的**处理路径（`_onPositionTick`）——
    //   不是在测试里另写一份"节流逻辑"（另写一份必然漂，铁律 170）
    const ticks = 180; // i=1..180 ⇒ 位置从 0s 走到正好 3.0s
    debugPlayerResetPositionSetStates();
    _install();
    for (var i = 1; i <= ticks; i++) {
      // 每 tick 推进 ~16.7ms，与 mpv 的 time-pos 频率同量级
      debugPlayerPushPositionForProbe(
          Duration(microseconds: (i * 1000000 / 60).round()));
      await t.pump();
    }
    print('PB|$ticks 次 tick（位置 0s→3.0s）=> 位置 setState '
        '${debugPlayerPositionSetStates} 次, 整页重建 $_page 次 / 元素重建 $_all 次');
    print('PB|（改前 1:1 ⇒ 180 次 tick 就是 180 次 setState、180 次整页重建）');
    expect(debugPlayerPositionSetStates, lessThanOrEqualTo(4),
        reason: '0s→3.0s 只跨 3 个秒边界 ⇒ 最多 4 次 setState（留 1 次余量）。'
            '超出 ⇒ `_onPositionTick` 的秒守卫被去掉了（改前这里是 180）');
    expect(_page, lessThanOrEqualTo(4),
        reason: '每次 setState 最多换来一次整页重建 ⇒ 同上');
    expect(debugPlayerPositionSetStates, greaterThanOrEqualTo(3),
        reason: '★ 下限同样重要：跨了 3 个秒边界就该更新 3 次时间显示。'
            '若少于 3 ⇒ 守卫写过头了，底栏时间会卡住不动');
  });

  // ═══ 候选 C：抽屉关着时不现取频道列表 ════════════════════════════════
  testWidgets('PC 抽屉关着：整页重建 N 次 ⇒ onLiveChannels 调 0 次；开着 ⇒ >=1', (t) async {
    if (!_requireLibmpv()) return;
    var calls = 0;
    await _mount(t, onLiveChannels: () => calls++);

    final before = calls;
    const forced = 10; // 强制 10 次确定的整页重建
    _install();
    for (var i = 0; i < forced; i++) {
      debugPlayerOpenHintsForProbe();
      await t.pump();
    }
    print('PC|抽屉关着：$forced 次整页重建（实测 page=$_page）'
        ' => onLiveChannels 被调 ${calls - before} 次（改前：1:1 ⇒ $forced 次）');
    expect(_page, greaterThanOrEqualTo(forced),
        reason: '阳性对照：这 $forced 次必须真的重建了整页，否则下面的断言是空的');
    expect(calls - before, 0,
        reason: '抽屉关着 ⇒ `_LiveChannelsSheet` 不挂载 ⇒ 传列表进去也没人看。'
            '不为 0 ⇒ `data:` 的开合守卫被去掉了');

    // ★ 反向对照：抽屉**开着**时必须照常取到列表（守卫没写坏）
    final beforeOpen = calls;
    final opened = debugPlayerOpenLiveChannelsForProbe();
    await t.pump();
    print('PC|抽屉开着(open=$opened)：onLiveChannels 被调 ${calls - beforeOpen} 次');
    expect(opened, isTrue, reason: '钩子要真的把抽屉打开');
    expect(calls - beforeOpen, greaterThanOrEqualTo(1),
        reason: '抽屉开着却取不到频道 ⇒ 守卫写过头了，面板会是空的');
  });

  // ═══ 回归：关闭时的退出动画期间**不能空白** ══════════════════════════
  testWidgets('PD 抽屉关闭 ⇒ 退出动画期间列表仍在（不是「所有直播（0）」）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, onLiveChannels: () {});

    final opened = debugPlayerOpenLiveChannelsForProbe();
    await t.pump();
    expect(opened, isTrue, reason: '钩子要真的把抽屉打开');
    expect(find.text('所有直播（2）'), findsOneWidget,
        reason: '抽屉开着时列表要渲染出来（阳性对照 —— 否则下面的断言是空的）');

    // 点 X 关闭（这是用户真实路径，不是直接改 state）
    await t.tap(find.byIcon(Icons.close));
    await t.pump(); // 处理抬起

    /*
     * ★★★ 必须**先等过双击窗口**（`kDoubleTapTimeout` = 300ms）再断言
     *
     * 本页 PC 上也挂着 `onDoubleTap`（全屏，`player_page.dart:6605`）
     * ⇒ 单击的 `onTap` 要等双击窗口过期才派发（同文件 L6494 注释）。
     *
     * ★ 红度证明抓到的教训（第一版这里只 pump 了 60ms）：
     * ```text
     * M6 把 `_liveChannelsForSheet` 改回"关着就是 null"（回归形态）
     * ⇒ 判定 MISSED ★ 判据是空的
     * ```
     * 原因：60ms < 300ms ⇒ **X 的 onTap 还没派发、抽屉压根没关**
     * ⇒ `data` 仍非 null ⇒ 列表当然还在
     * ⇒ 这条断言在"抽屉根本没关"和"关得好好的"两种情况下**都为真**
     *   —— 一条恒真的断言比没有断言更危险（它给的是虚假信心）。
     *
     * 修法 = 先跨过双击窗口（让关闭**真的发生**），
     * 再停在 220ms 退出动画**中途**（`SheetTransition` 的
     * `_mounted` 直到 reverse 结束才置 false ⇒ 此刻 child 仍在树上）。
     */
    await t.pump(const Duration(milliseconds: 320));
    expect(debugPlayerAnySheetOpen(), isFalse,
        reason: '前置：X 必须真的把抽屉关掉。'
            '★ 这条是上一条断言的**判别力前提** —— 少了它，'
            '"列表还在"就分不清是"退出动画期间仍在"还是"根本没关"');

    // 现在：抽屉已关（`_liveChannelsOpen == false`），
    //       但退出动画只跑了约 20ms ⇒ 正处在"关着、还在滑走"那一态
    await t.pump(const Duration(milliseconds: 60));

    /*
     * ★ 这条断言保护的是**我自己引入的回归**：
     *   C 修复若写成 `_liveChannelsOpen ? _liveChannels() : null`，
     *   关闭瞬间 data 就变 null，而 `SheetTransition` 仍挂着 child
     *   跑完 220ms 退出动画（`episode_strip.dart:1131-1153`）
     *   ⇒ 用户看到抽屉一边滑走一边把列表清空。
     *   `_liveChannelsForSheet()`（关着沿用上一次）正是为它而写。
     */
    expect(find.text('所有直播（2）'), findsOneWidget,
        reason: '退出动画期间列表被清空了 —— 抽屉会一边滑走一边变空。'
            '`_liveChannelsForSheet()` 的"关着沿用上次"被去掉了？');
    expect(find.text('所有直播（0）'), findsNothing,
        reason: '出现了「所有直播（0）」⇒ 正是空白回归本身');
  });
}
