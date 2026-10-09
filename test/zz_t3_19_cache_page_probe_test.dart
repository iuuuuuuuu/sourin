// ═══════════════════════════════════════════════════════════════════════
//  ⑲「已缓存」页 —— 真实扫盘实测（探针，不入库）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不是「断言一下 scanCacheWorks 返回了 2 个元素」
//
// Owner 要的是「显示出来缓存了多少」—— 那个数字**必须**来自真的文件系统。
// 所以这份探针**真的建目录、真的写真文件、真的写字节**，再读回来对体积。
//
// ⚠️ 沙盒一律 _sandboxRoot()（绝对路径 + 收尾自清理）—— 探针产物
//    绝不许落在仓库根（这是硬规则，出过一次事）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart'; // debugShellKey / ShellPage / AppTab
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
// BottomBarMarker 不在 shell.dart 里，定义在 spatial_nav.dart:1124
import 'package:sourin_spike/ui/spatial_nav.dart' show BottomBarMarker;

/// ★ 探针沙盒根 —— 必须是绝对路径，且落在系统临时目录下
Directory _sandboxRoot() {
  final p = '${Directory.systemTemp.absolute.path}\\t3_19';
  final d = Directory(p);
  if (!d.isAbsolute) {
    fail('★ 探针沙盒必须是绝对路径，实际 = $p');
  }
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 写一个指定字节数的假视频（内容无所谓，长度就是判据）
File _writeBytes(String path, int bytes, {bool part = false}) {
  final f = File(part ? '$path.part' : path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x41));
  return f;
}

/// 与生产外壳一致的包装（照抄 test/bottom_bar_fit_test.dart:55-65）
///
/// ⚠️ 为什么不能只挂 mui.MaterialApp：本项目的外壳是
///    FTheme（forui，装 **中性暗色桌面** 主题）+ MaterialApp。
///    主题缺了之后 RefreshIndicator 的 material 默认样式与
///    Material 层都没了 —— 实测报的是
///    「Null check operator used on a null value @ StretchingOverscrollIndicator」
///    （material_ui-1.6.0/lib/src/app.dart:837）这类**仪器异常**，
///    整页会被换成 ErrorWidget，断言只会以「找不到 XX」失败，
///    真因只在 stderr ⇒ 属于**探针假阴性**，不是页面缺陷。
Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const mui.SizedBox(),
    ),
    home: home,
  );
}

/// 认领一次 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

void main() {
  late Directory root;

  setUp(() {
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    root = Directory(
      '${_sandboxRoot().path}\\case-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
  });

  tearDownAll(() {
    final d = Directory('${Directory.systemTemp.absolute.path}\\t3_19');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除探针沙盒 ${d.path} 存在=${d.existsSync()}');
  });

  test('★ 真扫盘：两集 + 一个 .part + 旁文件 + 一个非视频，体积逐项对', () async {
    _writeBytes('${root.path}\\我的剧\\第01集 开局.mp4', 1024 * 1024);
    _writeBytes('${root.path}\\我的剧\\第02集 反转.mp4', 512 * 1024);
    // 正在下：*.part 必须算体积、但不算「集」
    _writeBytes('${root.path}\\我的剧\\第03集 收尾.mp4', 256 * 1024, part: true);
    // 旁文件：带封面 + 剧名
    File('${root.path}\\我的剧\\$kCacheSidecarName').writeAsStringSync(
      '{"provider":"cctv","id":"cctv1","title":"我的剧",'
      '"cover":"https://example.com/c.jpg"}',
    );
    // 非视频：不算集
    File('${root.path}\\我的剧\\readme.txt').writeAsStringSync('x');
    // 第二部：没有旁文件（模拟老下载）
    _writeBytes('${root.path}\\没旁文件\\a.mp4', 2 * 1024 * 1024);

    final works = await scanCacheWorks(root.path);
    debugPrint('SCAN 扫到 ${works.length} 部');
    for (final w in works) {
      debugPrint('SCAN   ${w.dirName} | 标题=${w.displayTitle} '
          '| 完成=${w.completedCount} 在下=${w.partialCount} '
          '| 字节=${w.bytes}（${humanBytes(w.bytes)}）'
          '| 封面=${w.cover ?? "(无)"} | provider=${w.provider ?? "(无)"}');
    }

    expect(works.length, 2, reason: '★ 两个子目录 = 两部作品');

    final a = works.firstWhere((w) => w.dirName == '我的剧');
    expect(a.episodes.length, 3, reason: '★ 三个视频文件（含 .part）都要被扫到');
    expect(a.completedCount, 2, reason: '★ .part 不算「已完成」');
    expect(a.partialCount, 1, reason: '★ 一个正在下');
    expect(a.bytes, 1024 * 1024 + 512 * 1024 + 256 * 1024,
        reason: '★★ 体积**必须含 .part** —— 不然正在下 8G 时页面显示 0');
    expect(a.displayTitle, '我的剧', reason: '★ 旁文件里的剧名优先');
    expect(a.cover, 'https://example.com/c.jpg', reason: '★ 封面来自旁文件');
    expect(a.provider, 'cctv');
    expect(humanBytes(a.bytes), '1.8 MiB',
        reason: '★ 1024 进制、1 位小数（与资源管理器对得上）');

    // ★ 旁文件自己**不能**被当成一集（否则会多出第 4 集）
    expect(a.episodes.any((e) => e.fileName == kCacheSidecarName), isFalse,
        reason: '★ 旁文件必须被跳过');
    expect(a.episodes.any((e) => e.fileName == 'readme.txt'), isFalse,
        reason: '★ 非视频后缀不算集');

    final b = works.firstWhere((w) => w.dirName == '没旁文件');
    expect(b.cover, isNull, reason: '★ 没旁文件 ⇒ 不编造封面');
    expect(b.displayTitle, '没旁文件',
        reason: '★★ 退回**目录名**（safeName 不可逆，不能反推剧名）');
  });

  test('★ 空目录 / 不存在的目录都返回空表（不抛）', () async {
    expect(await scanCacheWorks(root.path), isEmpty);
    expect(await scanCacheWorks('${root.path}\\不存在'), isEmpty);
  });

  test('★ 坏旁文件只降级成「无封面」，不让整页失败', () async {
    _writeBytes('${root.path}\\坏元数据\\e1.mp4', 4096);
    File('${root.path}\\坏元数据\\$kCacheSidecarName')
        .writeAsStringSync('这不是 JSON{{{');
    final works = await scanCacheWorks(root.path);
    expect(works.length, 1);
    expect(works.first.cover, isNull);
    expect(works.first.dirName, '坏元数据');
  });

  testWidgets('★★ 真渲染：屏幕上真的出现「已缓存 / 1.0 MiB / 1 集」', (t) async {
    // ★★ 探针壳必须补 MaterialLocalizations：CachePage 本体是 RefreshIndicator
    //    （cache_page.dart:386），它在 build 里会 debugCheckHasMaterialLocalizations，
    //    探针壳若只挂 MaterialApp 就会抛 "No MaterialLocalizations found" ——
    //    上一轮那 2 条红就是这么来的，**是探针壳缺东西，不是 CachePage 的缺陷**
    //    （真站点上 CachePage 永远挂在 shell 的 MaterialApp 之下）。
    //    ⇒ 这里按项目的真实壳子挂 mui.MaterialApp（本项目 UI 走 material_ui 包，
    //      test/ 下既有用例也是这么挂的）。
    CachePage.debugScanRootOverride = root.path;
    _writeBytes('${root.path}\\剧A\\第01集 x.mp4', 1024 * 1024);
    File('${root.path}\\剧A\\$kCacheSidecarName').writeAsStringSync(
      '{"provider":"cctv","id":"cctv1","title":"剧A","cover":null}',
    );
    DownloadDir.setConfiguredDir(root.path);

    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    // ★★ 为什么必须用 runAsync：扫盘是**真碰盘**的真异步 IO，而 t.pump 走的是
    //    受控（fake）时钟 —— 真实 IO 的 future 在 fake async 区里永不完成，
    //    页面会永远停在 loading（上一轮就是这么红的，是探针假阴性不是页面坏）。
    //    runAsync 换到真实事件循环里泵，IO 才会真的推进。
    await t.runAsync(() async {
      await t.pumpWidget(mui.MaterialApp(
        home: mui.Scaffold(body: CachePage()),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    await t.pump();

    // ★ 诊断：先看树里到底有什么（loading? 异常?）
    debugPrint('RENDER CachePage 个数=${find.byType(CachePage).evaluate().length}');
    debugPrint('RENDER CircularProgressIndicator 个数='
        '${find.byType(CircularProgressIndicator).evaluate().length}');
    debugPrint('RENDER Text 个数=${find.byType(Text).evaluate().length}');
    debugPrint('RENDER RefreshIndicator 个数='
        '${find.byType(RefreshIndicator).evaluate().length}');
    final st = t.state<CachePageState>(find.byType(CachePage));
    debugPrint('RENDER 页面状态 loading=${st.debugLoading} '
        'error=${st.debugError} root=${st.debugRoot} '
        'works=${st.debugWorkCount} loadCount=${st.debugLoadCount}');

    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    debugPrint('RENDER 屏幕上的文字：');
    for (final s in texts) {
      debugPrint('RENDER   「$s」');
    }
    // ★ 收尾：走完 UiPrefs 的防抖落盘 timer（同下一条用例的理由）。
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('已缓存'), findsOneWidget, reason: '★ 页面标题');
    expect(find.textContaining('1.0 MiB'), findsWidgets,
        reason: '★★ 缓存大小必须**真的显示出来**（Owner 的原话）');
    expect(find.textContaining('1 集'), findsWidgets, reason: '★ 集数');
    expect(find.text('剧A'), findsWidgets, reason: '★ 卡片标题（旁文件剧名）');
  });

  testWidgets('★ 空态：没下载过时给一句话而不是白屏', (t) async {
    DownloadDir.setConfiguredDir(root.path);
    CachePage.debugScanRootOverride = root.path;
    await t.runAsync(() async {
      await t.pumpWidget(mui.MaterialApp(
        home: mui.Scaffold(body: CachePage()),
      ));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    await t.pump();
    // ★ 收尾：让 UiPrefs 的防抖落盘定时器（0.3s）到期，否则 flutter_test 会判
    //   "A Timer is still pending even after the widget tree was disposed"。
    //   这与页面无关：setConfiguredDir 写 pref 时 UiPrefs._flushSoon 起了个防抖
    //   timer（ui_prefs.dart:109），受控时钟下要显式把它走完。
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('还没有下载过东西'), findsOneWidget,
        reason: '★★ 空态必须可读（不能是白屏）');
  });
  // ══════════════════════════════════════════════════════════════════
  //  ★★ 端到端：真的挂 ShellPage，真的点底栏「已缓存」，真的进页
  //
  //  为什么必须有这一条：上面几条都是**直接挂 CachePage**（绕开壳子）。
  //  但用户看到的是底栏那个入口 —— 而底栏是 `for (final t in AppTab.values)`
  //  按**枚举顺序**画的（lib/shell.dart），如果 `AppTab.cached` 的图标没在
  //  `_icons` / `_iconsActive` 里补齐，`icon()` 里的 `[this]!` 会在**运行时**
  //  才 null 崩（不是编译期）—— 只有真挂壳子才会炸出来。
  // ══════════════════════════════════════════════════════════════════
  testWidgets('★★ 端到端：挂真 ShellPage → 点底栏「已缓存」→ 真的进页并列出缓存',
      (t) async {
    // 先造一份真缓存（1 MiB），并把扫描根指过去
    _writeBytes('${root.path}\\剧A\\第01集 x.mp4', 1024 * 1024);
    File('${root.path}\\剧A\\$kCacheSidecarName').writeAsStringSync(
      '{"provider":"cctv","id":"cctv1","title":"剧A","cover":null}',
    );
    CachePage.debugScanRootOverride = root.path;
    DownloadDir.setConfiguredDir(root.path);

    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1280, 800);
    addTearDown(t.view.reset);

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
    });
    await t.pump(const Duration(milliseconds: 1200));
    // ★ 认领环境异常：本机没有 sourin_core.dll，Shell 各页 loadAll 会抛
    //   FFI 异常（test/bottom_bar_fit_test.dart 的 _claim 就是干这个的），
    //   同时 home_page 的 SliverPersistentHeader 在测试仪器里也会抛
    //   SliverGeometry 断言（与 ⓘ 无关，见下方说明）——
    //   这些都不是被测行为，必须收掉，否则测试只会以
    //   "Multiple exceptions were detected" 失败，真读数被淹掉。
    //   ⚠️ 收在「渲染稳定之后」：收敛需要几帧，早收会漏。
    _claim(t);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 80));
      _claim(t);
    }

    // ── ① 底栏里真的有「已缓存」这个入口（渲染出来的，不是源码里的）──
    // ⚠️ 这里 skipOffstage: false 是**必须的**，不是随手加的 ——
    //    默认 true 时元素树遍历会走 _ViewportElement.debugVisitOnstageChildren
    //    → viewport.dart:355 那个 parentData 空断言，复杂树下会在
    //    **测试仪器**里抛 "Null check operator used on a null value"，
    //    tap() 的 hit-test 也要走同一条遍历（controller.dart:1078）。
    //    skipOffstage: false 走 visitChildren 那条路 ⇒ 绕开它。
    //    （test/bottom_bar_fit_test.dart:105-117 记的是同一个坑。）
    final entry = find.descendant(
      of: find.byType(BottomBarMarker, skipOffstage: false),
      matching: find.text('已缓存', skipOffstage: false),
      skipOffstage: false,
    );
    debugPrint('E2E 底栏「已缓存」入口个数=${entry.evaluate().length}');
    expect(entry, findsOneWidget, reason: '★ 底栏必须有「已缓存」入口');

    // ── ② 真的点它（press 到真实 hit-test 位置，不是调回调）──
    //    先认领一次积压的环境异常：本机没有 sourin_core.dll，
    //    Shell 里各页 loadAll 都会抛 FFI 异常（test/bottom_bar_fit_test.dart
    //    的 _claim 就是干这个的）—— 那是**环境**，不是被测行为。
    _claim(t);
    // ⚠️ 不能用 t.tap(entry)：WidgetController.tap 内部要 _maybeViewOf →
    //    元素树遍历，而这里 finder 带 skipOffstage: false ⇒ 它照样会去
    //    摸 onstage 子树并撞上 viewport.dart:355 的 parentData 空断言
    //    （实测抛在 controller.dart:1078，与 finder 无关，绕不开）。
    //    ⇒ 改成**真按坐标打**：getCenter 走 RenderObject 几何（不遍历元素树），
    //      tapAt 直接对坐标做 hit-test ⇒ 走的仍是真实的 RenderPointerListener
    //      路由（等价于手指真的落在那个像素上），不是直接调回调。
    final target = entry.evaluate().isEmpty
        ? null
        : t.getCenter(entry.first);
    debugPrint('E2E 命中点=$target');
    expect(target, isNotNull, reason: '★ 必须能量到底栏「已缓存」的命中点');
    await t.tapAt(target!);
    await t.pump();
    // ★★ 为什么点完还要 runAsync：切到「已缓存」时 _switchTo 会调
    //    _cachedKey.currentState?.load()，而 load() 里是真异步 IO
    //    （_scanWork 走 dart:io）。**受控（fake）时钟里真 IO 的 future
    //    永不完成** —— 只 pump 的话页面会一直停在 loading，
    //    屏幕上一个字节数都读不到（这条我已经踩过一次，见文件头）。
    //    ⇒ 必须换到真实事件循环里泵，IO 才会真的推进并 setState。
    //    ⚠️ _claim 必须放在 runAsync **外面**：runAsync 里 t.pump 抛出的异常
    //      不会经过外层 zone，早收会漏掉（实测漏 14 条）。
    for (var i = 0; i < 12; i++) {
      await t.runAsync(() async {
        for (var j = 0; j < 3; j++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await t.pump();
        }
      });
      _claim(t);
    }
    await t.pump(const Duration(milliseconds: 400));
    _claim(t);

    // ── ③ 切过去了：当前 tab 是 cached ──
    final shell = debugShellKey.currentState!;
    debugPrint('E2E 点击后当前 tab=${shell.debugCurrentTab}');
    expect(shell.debugCurrentTab, AppTab.cached, reason: '★ 点完必须切到已缓存页');

    // ── ④ 页面真的渲染出来（在整棵 shell 树里找）──
    final texts = t
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    debugPrint('E2E 整棵树里的文字（含离场页）：${texts.length} 条');
    for (final s in texts.where((s) => s.contains('缓存') || s.contains('MiB'))) {
      debugPrint('E2E   「$s」');
    }
    expect(find.text('已缓存', skipOffstage: false), findsWidgets,
        reason: '★★ 用户必须真的看到「已缓存」页');
    expect(find.textContaining('1.0 MiB', skipOffstage: false), findsWidgets,
        reason: '★★ 缓存大小必须真的显示出来');
    expect(find.text('剧A', skipOffstage: false), findsWidgets,
        reason: '★ 卡片标题');

    // ★ 收尾：走完 UiPrefs 的防抖 timer
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(milliseconds: 100));
  });
}
