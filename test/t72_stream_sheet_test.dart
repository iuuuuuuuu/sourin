// ═══════════════════════════════════════════════════════════════════════
//  task-72【①】【②】线路抽屉：标清晰度 + 点空白关闭（不透层）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么用探针驱动（而不是手抄一份面板）
// ```text
// 「线路」按钮的门控是 `hasStreams: _streams.length > 1`，而 `_streams` 只在
// `resolve_stream`（FFI）成功后才填 —— widget 测试里 `sourin_core.dll`
// **加载不了**（实测 error code 126）⇒ 按钮永远不会出现。
// ⇒ 用 `debugPlayerSetStreamsForProbe` / `debugPlayerOpenStreamSheetForProbe`
//   驱动**真实的** `_streams` / `_streamSheetOpen`，测的就是生产那棵树。
//   ★ task-70 的教训：手抄副本会与生产脱钩 ⇒ **测试全绿、生产是错的**。
// ```
//
// # ① 的判据为什么必须落在"两个字段都显示"
// ```text
// `models.dart:779`  `displayName => label ?? quality ?? ...`  ← ★ 短路
// ⇒ 只要源给了 `label`（如「哔哩哔哩 1080P」「次元城」），
//   **quality 永远看不到** —— 而抽屉表头写着「线路 / 清晰度」。
// ★ 但**不能**无脑把 quality 贴上去：哔哩哔哩的 label 里**已经含**
//   清晰度 ⇒ 会变成「哔哩哔哩 1080P  1080P」。
// ⇒ 判据 = `qualityBadgeFor` 的三态（去重 / 显示 / 不显示），
//   并且**去重那条必须与"显示那条"写在一起**（否则改坏了没人抓）。
// ```
//
// ⚠️ 只断言事实，不做主观判断。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '线路抽屉测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
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
// ★ 本文件只有 **4 个 testWidgets** 依赖播放器；group ① 的 6 条是 `qualityBadgeFor` 的**纯函数**测试（不碰 MediaKit）⇒ **不加**守卫，照跑。
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
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ① 清晰度徽章 —— 纯函数三态
  // ═══════════════════════════════════════════════════════════════════
  group('① qualityBadgeFor 三态', () {
    test('标签已含清晰度 ⇒ 返回空串（不重复贴）', () {
      const s = StreamCandidate(
        url: 'u',
        label: '哔哩哔哩 1080P',
        quality: '1080P',
      );
      expect(qualityBadgeFor(s), '',
          reason: '★ 这是**去重**那条：label 里已经写了 1080P，'
              '再贴一个徽章会变成「哔哩哔哩 1080P  1080P」。'
              '它返回非空 ⇒ 去重逻辑被去掉了');
    });

    test('大小写不同也算"已含"（1080p vs 1080P）', () {
      const s = StreamCandidate(
        url: 'u',
        label: '官方 HLS 1080p',
        quality: '1080P',
      );
      expect(qualityBadgeFor(s), '',
          reason: '源给的 label 与 quality 大小写常常不一致 ⇒ 比较必须忽略大小写。'
              '否则同一条线路会重复显示清晰度');
    });

    test('标签不含清晰度 ⇒ 返回清晰度本身', () {
      const s = StreamCandidate(url: 'u', label: '次元城', quality: '原画');
      expect(qualityBadgeFor(s), '原画',
          reason: '★ 这是**显示**那条（与上面两条同处一个 group —— '
              '去重与显示必须一起测，只测一条会让另一条退化）');
    });

    test('只有 quality、没有 label ⇒ 空串（displayName 已是 quality）', () {
      const s = StreamCandidate(url: 'u', quality: '1080P');
      expect(qualityBadgeFor(s), '',
          reason: 'label 为空时 displayName 会退回 quality ⇒ 再贴徽章就是重复');
    });

    test('只有 label、没有 quality ⇒ 空串（没东西可贴）', () {
      const s = StreamCandidate(url: 'u', label: '官方 HLS');
      expect(qualityBadgeFor(s), '');
    });

    test('两个都没有 ⇒ 空串', () {
      const s = StreamCandidate(url: 'u', kind: 'hls');
      expect(qualityBadgeFor(s), '');
    });

    test('首尾空白不算内容（" 原画 " 与 "次元城"）', () {
      const s = StreamCandidate(url: 'u', label: '次元城', quality: '  原画  ');
      expect(qualityBadgeFor(s), '原画',
          reason: '必须 trim —— 否则徽章会带着空格渲染，'
              '或"label 含 quality"的包含判断失效');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 清晰度徽章 —— 真实 widget 树（四种候选一起渲染）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('① 真实抽屉：线路名与清晰度**同时**可见，且不重复', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    const streams = <StreamCandidate>[
      // 1) 次元城：label 不含清晰度 ⇒ **应当**出现徽章「原画」
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '次元城', quality: '原画'),
      // 2) 哔哩哔哩：label 已含清晰度 ⇒ **不应当**再出现徽章
      StreamCandidate(
          url: 'https://x.invalid/2.m3u8', label: '哔哩哔哩 1080P', quality: '1080P'),
      // 3) 只有 quality ⇒ displayName 就是 1080P，无徽章
      StreamCandidate(url: 'https://x.invalid/3.m3u8', quality: '1080P'),
      // 4) 只有 label ⇒ 无徽章
      StreamCandidate(url: 'https://x.invalid/4.m3u8', label: '官方 HLS'),
    ];

    expect(debugPlayerSetStreamsForProbe(streams), isTrue,
        reason: '探针要真的把线路注入进去，否则下面的断言全是空的');
    final opened = debugPlayerOpenStreamSheetForProbe();
    await t.pump();
    expect(opened, isTrue, reason: '抽屉要真的打开');
    expect(debugPlayerAnySheetOpen(), isTrue,
        reason: '阳性对照：抽屉确实处于打开态');

    // ── 四条线路名都在（证明列表渲染了）────────────────────────────
    expect(find.text('次元城'), findsOneWidget);
    expect(find.text('哔哩哔哩 1080P'), findsOneWidget);
    expect(find.text('官方 HLS'), findsOneWidget);

    // ── ★ 徽章：次元城的「原画」必须出现 ──────────────────────────
    expect(find.text('原画'), findsOneWidget,
        reason: '线路名「次元城」不含清晰度 ⇒ 必须补一个「原画」徽章。'
            '找不到 ⇒ ① 的修复被去掉了（用户看不到清晰度）');

    // ── ★ 去重：'1080P' 只应出现**一次**（第 3 条线路名）───────────
    expect(find.text('1080P'), findsOneWidget,
        reason: '★ 若哔哩哔哩那条也贴了徽章，这里会变成 2 —— '
            '正是"label 已含清晰度却又贴一遍"的重复显示。'
            '（第 3 条的 displayName 本身就是 1080P，所以基线是 1）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 点抽屉外的空白 ⇒ 关闭（不透层）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('② 点左侧空白 ⇒ 抽屉关闭（改前：点不动，穿透到下层）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    debugPlayerSetStreamsForProbe(const [
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: 'A', quality: '1080P'),
      StreamCandidate(url: 'https://x.invalid/2.m3u8', label: 'B', quality: '720P'),
    ]);
    final opened = debugPlayerOpenStreamSheetForProbe();
    await t.pump();
    expect(opened, isTrue);
    expect(debugPlayerAnySheetOpen(), isTrue);

    /*
     * ★ 面板贴右边、宽 320 ⇒ 左边 960px 是"没有 widget 的空白"。
     *   改前那里点击会**穿透**到下层（Owner 原话：
     *   「点击空白处应该是就关闭,而不是透层点击」）。
     *   改后 `_SheetScrim`（`HitTestBehavior.opaque`）吸收这一击。
     */
    await t.tapAt(const Offset(100, 400));
    print('T72②|抬起后、等双击窗口前: anySheet=${debugPlayerAnySheetOpen()}');

    /*
     * ★★★ 为什么必须多等 400ms（这是**实测**出来的，不是保险起见）
     *
     * 本页在 PC 上也挂着 `onDoubleTap` = 全屏
     *（`player_page.dart:6605`；`kDoubleTapTimeout` = 300ms，见 L6494 注释）。
     * ⇒ 屏幕上的**任何**单击，其 `onTap` 都要等**双击窗口过期**才派发
     *   —— 屏障那一击也不例外。
     *
     * 证据（第一版测试只 `pump()` 零时长，直接红）：
     * ```text
     * Expected: false   Actual: <true>      ← 抽屉没关
     * Pending timers: Timer(0:00:00.040000)  ← _TapTracker（kDoubleTapMinTime）
     *   #7 DoubleTapGestureRecognizer._trackTap
     * ```
     * ⇒ 不 pump 这段时间，测的就不是"屏障有没有生效"，
     *   而是"手势竞技场还没裁完" —— 一条测不出东西的断言。
     *
     * ⚠️ 不能用 `pumpAndSettle`：本页有 5 秒周期定时器
     *   （`_progressTimer`）与 3 秒的 `_hideTimer` ⇒ 永远 settle 不下来。
     */
    await t.pump(const Duration(milliseconds: 400));
    print('T72②|等过双击窗口后: anySheet=${debugPlayerAnySheetOpen()}');

    expect(debugPlayerAnySheetOpen(), isFalse,
        reason: '★ 点抽屉外的空白必须关闭它。仍为 true ⇒ 屏障没了或被挪到'
            '`SheetTransition` 外面（后者更糟：抽屉关了还会吸收全屏点击）');
  });

  testWidgets('② 点抽屉**内部** ⇒ 不关闭（证明屏障没盖住面板）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    debugPlayerSetStreamsForProbe(const [
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: 'A', quality: '1080P'),
      StreamCandidate(url: 'https://x.invalid/2.m3u8', label: 'B', quality: '720P'),
    ]);
    debugPlayerOpenStreamSheetForProbe();
    await t.pump();

    // 表头文字（面板内部，本身没有 onTap）—— 点它什么都不该发生
    final header = find.text('线路 / 清晰度');
    expect(header, findsOneWidget, reason: '表头要渲染出来，否则这条测不到面板内部');

    final rect = t.getRect(header);
    print('T72②|表头 rect=$rect（面板贴右、宽 320 ⇒ 应落在 x>960）');
    expect(rect.left, greaterThan(960),
        reason: '表头必须落在右侧面板内（否则"点内部"其实点在空白上，'
            '这条断言就变成了另一条测试的副本）');

    await t.tap(header);
    /*
     * ★ 同样要等过双击窗口（理由见上一条测试的长注释）：
     *   不等的话，点击的 `onTap` 还没派发，而且 `_TapTracker` 的
     *   40ms 定时器会挂到 teardown ⇒ 报
     *   「A Timer is still pending even after the widget tree was disposed」，
     *   **测试会因为一个与断言无关的原因变红**（我第一版就是这样）。
     */
    await t.pump(const Duration(milliseconds: 400));

    expect(debugPlayerAnySheetOpen(), isTrue,
        reason: '★ 点面板内部不该关闭抽屉。'
            '若变 false ⇒ 屏障盖住了面板（命中顺序反了：`RenderStack` '
            '从最后一个子节点往前测，面板必须在屏障**之后**）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 几何回归：task-70 的阻断级缺陷不许回来
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('② 几何：面板仍是**右侧 320**（task-70 的回归守卫）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    debugPlayerSetStreamsForProbe(const [
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: 'A', quality: '1080P'),
      StreamCandidate(url: 'https://x.invalid/2.m3u8', label: 'B', quality: '720P'),
    ]);
    debugPlayerOpenStreamSheetForProbe();
    await t.pump();

    // 面板的有色区域 = 那个 ColoredBox（宽 320、贴右、全高）
    final box = find.byWidgetPredicate((w) =>
        w is ColoredBox &&
        w.color == Colors.black.withValues(alpha: 0.92));
    expect(box, findsWidgets, reason: '面板的有色区域必须还在（它是吸收点击的东西）');

    final rect = t.getRect(box.first);
    print('T72②|面板有色区域 rect=$rect');
    expect(rect.width, 320.0,
        reason: '★ task-70 的阻断级缺陷：`_StreamSheet` 曾自带 `Positioned`，'
            '与外层 `Positioned.fill` 冲突 ⇒ release 下断言被剥离 ⇒ '
            '面板撑满 1280 并吸收所有点击。宽度不是 320 ⇒ 那个缺陷回来了');
    expect(rect.right, 1280.0, reason: '面板必须贴右边');
  });
}
