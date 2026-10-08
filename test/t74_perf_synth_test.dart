// ═══════════════════════════════════════════════════════════════════════
//  task-74【⑤】「你自己再全部跑一下性能测试，把卡顿的点给优化优化」
//  —— **合成**（`flutter test`）那一半：重建面 + 墙钟
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一半**能量什么**、**不能量什么**（先说清，免得读数被误读）
//
// ```text
// ✅ 能：元素重建次数（"重建面"）—— `debugOnRebuildDirtyWidget`
// ✅ 能：一帧 build 的**墙钟**（`Stopwatch` 包住 `tester.pump()`）
// ✅ 能：几何 / 结构（有没有真的渲染、滚没滚、前置条件成不成立）
// ❌ 不能：raster 耗时（`flutter test` 里没有真实 GPU / 光栅线程）
// ❌ 不能：真机 mpv 的 tick 频率（那是 ④ 的探针，`.probe/t72p-realplayback.txt`）
// ❌ 不能：挂真 `Player` / 调 `open()` —— 会挂死 10 分钟（本仓踩过两次）
// ❌ 不能：`RepaintBoundary.toImage()` —— 同上，必须 `tester.runAsync()` 或真机
// ```
//
// ★★ 结论口径：本文件的读数**只是"重建面"**，不是"帧耗时"。
//    它与真机 `raster` 耗时**不是同一个量**（铁律 221：代理指标 ≠ 目标现象）
//    ⇒ 报告里必须分开写，不许把这里的数字说成"不卡"。
//
// # 仪器 ①：元素重建计数器
// ```text
// Flutter SDK `widgets/framework.dart` `Element.rebuild()`：
//     assert(() { debugOnRebuildDirtyWidget?.call(this, _debugBuiltOnce); ... }());
// ⇒ 每个 dirty 元素每次重建回调一次 ⇒ 回调总数 = 这一帧真正重建的元素总数。
// ★ 它在 `assert()` 里 ⇒ **release 构建里整段被剥掉**
//   ⇒ 只能用于测试（这正是本文件存在的理由）。
// ```
//
// # 仪器 ②：墙钟（`Stopwatch` 包住 `tester.pump()`）
// ```text
// `tester.pump()` 在 fake-async 里**同步**跑完 build/layout/paint
// ⇒ 包住它的墙钟 = 这一帧 build 阶段的真实 CPU 时间。
// ⚠️ 它**不含** raster（测试里没有光栅线程）⇒ 只代表"构建侧"。
// ```
//
// # ★★★ 反自欺（task-55 立的规矩：假阳性比假阴性更危险）
// ```text
// ① 阴性对照：装好仪器、pump 一帧而**不改**任何状态 ⇒ 必须 0。
// ② 阳性对照：调一个**确定**会 setState 的钩子 ⇒ 必须 >=1。
// ③ ★ 墙钟仪器的阳性对照：故意在 build 里**同步忙等 200ms**
//    ⇒ 必须读到 >=150000us。读不到 ⇒ 报「仪器不可信」，
//      **不许**把"读数为 0"当成"不卡"交上去。
// ```
//
// ⚠️ 只打印事实 + 断言；不打印结论。

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';

// ═══════════════════════════════════════════════════════════════════════
//  仪器 ①：元素重建计数器
// ═══════════════════════════════════════════════════════════════════════

/// 这一帧**所有**元素的重建次数之和
int _all = 0;

/// 这一帧 `watch` 类型的元素重建次数
int _watched = 0;

/// 装表（`watch != null` 时额外单独计数该类型）
void _install([Type? watch]) {
  _all = 0;
  _watched = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (watch != null && e.widget.runtimeType == watch) _watched++;
  };
}

void _uninstall() => debugOnRebuildDirtyWidget = null;

// ═══════════════════════════════════════════════════════════════════════
//  仪器 ②：墙钟
// ═══════════════════════════════════════════════════════════════════════

/// pump 一帧，返回它的墙钟微秒数
Future<int> _pumpMicros(WidgetTester t) async {
  final sw = Stopwatch()..start();
  await t.pump();
  sw.stop();
  return sw.elapsedMicroseconds;
}

/// ★ 墙钟仪器的**阳性对照件**：`build` 里同步忙等 `blockMs` 毫秒。
///
/// 这不是"模拟卡顿"，这就是卡顿本身（UI 线程被占住）。
/// 仪器若读不到它 ⇒ 仪器坏 ⇒ 后面所有"不卡"的读数一律作废。
class _Jank extends StatefulWidget {
  const _Jank({super.key});

  @override
  State<_Jank> createState() => _JankState();
}

class _JankState extends State<_Jank> {
  int blockMs = 0;
  int n = 0;

  void bump({int block = 0}) {
    setState(() {
      blockMs = block;
      n++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (blockMs > 0) {
      final sw = Stopwatch()..start();
      // ignore: avoid_while_loop
      while (sw.elapsedMilliseconds < blockMs) {
        // 故意占住 UI 线程
      }
    }
    return Text('jank $n');
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// 认领环境噪声（无核心 DLL 的 FFI 异常等）
void _claim(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null) {
    if (++n > 200) break;
  }
}

/// 把树上真实存在的 widget 类型打出来（诊断"前置不成立"用）
///
/// ★ 为什么需要它：`expect(finder, findsWidgets)` 失败只说"没找到"，
///   而"为什么没找到"（是页面没渲染？还是渲染成了别的东西？）
///   必须靠**树上真有什么**才能回答。
String _dumpTypes(WidgetTester t, {int limit = 40}) {
  final counts = <String, int>{};
  for (final w in t.allWidgets) {
    final n = w.runtimeType.toString();
    counts[n] = (counts[n] ?? 0) + 1;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted
      .take(limit)
      .map((e) => '${e.key}×${e.value}')
      .join(', ');
}

/// 只报**关心的那几个**类型各出现几次（不受截断影响）
String _countTypes(WidgetTester t, List<String> names) {
  final counts = <String, int>{};
  for (final w in t.allWidgets) {
    final n = w.runtimeType.toString();
    counts[n] = (counts[n] ?? 0) + 1;
  }
  return names.map((n) => '$n=${counts[n] ?? 0}').join(' ');
}

/// 认领环境噪声，但**把异常记下来**（用于"前置不成立"时说明真因）
///
/// ★ 为什么需要它：`_claim()` 把异常吞掉之后，"找不到 ListView"这种
///   前置失败会以**误导性**的理由报出来（看起来像 `_loading` 卡住），
///   而真因（比如缺某个祖先 scope）只出现在 stderr 里。
List<String> _claimLogged(WidgetTester t) {
  final seen = <String>[];
  var n = 0;
  while (true) {
    final e = t.takeException();
    if (e == null) break;
    if (seen.length < 5) seen.add(e.toString().split('\n').first);
    if (++n > 200) break;
  }
  return seen;
}

/// 打印一组读数的分位数（**只打印事实**）
String _stat(List<int> xs) {
  if (xs.isEmpty) return 'n=0';
  final s = <int>[...xs]..sort();
  int at(double q) => s[((s.length - 1) * q).round()];
  final sum = s.fold<int>(0, (a, b) => a + b);
  return 'n=${s.length} p50=${at(0.50)} p95=${at(0.95)} '
      'max=${s.last} sum=$sum';
}

Widget host(Widget child, Size size) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

Future<void> sizeView(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 造一条续播记录
Progress mkProgress(int i) => Progress(
      key: 'cycani:$i',
      provider: 'cycani',
      nativeId: '$i',
      title: '剧名$i',
      episodeTitle: '第0${i % 9 + 1}集',
      position: 100 + i,
      duration: 2400,
      updatedAt: 1700000000 + i,
    );

const _size = Size(1280, 900);

void main() {
  tearDown(_uninstall);

  // ═══════════════════════════════════════════════════════════════════
  //  P0a 仪器自检 ①：重建计数器 阴性 0 / 阳性 >=1
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('P0a 仪器自检：阴性对照 0 / 阳性对照 >=1', (t) async {
    await sizeView(t, _size);
    final k = GlobalKey<_JankState>();
    await t.pumpWidget(host(_Jank(key: k), _size));
    await t.pump();

    // 阴性：装好表、pump 一帧而**不改**任何状态
    _install();
    await t.pump();
    // ignore: avoid_print
    print('P0a|阴性对照 pump(无状态变化) => all=$_all');
    expect(_all, 0,
        reason: '静置帧不该有任何元素重建 —— 不为 0 说明仪器或页面有问题');

    // 阳性：调一个**确定**会 setState 的钩子
    _install();
    k.currentState!.bump();
    await t.pump();
    // ignore: avoid_print
    print('P0a|阳性对照 bump() => all=$_all watched=$_watched');
    expect(_all, greaterThanOrEqualTo(1),
        reason: '★ 阳性对照必须 >=1 —— 否则仪器没有区分力'
            '（一条永远为真的断言比没有断言更危险）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  P0b 仪器自检 ②：墙钟能读出 200ms 同步阻塞
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('P0b 仪器自检：注入 200ms 同步阻塞 ⇒ 墙钟必须读到 >=150000us',
      (t) async {
    await sizeView(t, _size);
    final k = GlobalKey<_JankState>();
    await t.pumpWidget(host(_Jank(key: k), _size));
    await t.pump();

    // 阴性：不改状态
    final neg = await _pumpMicros(t);
    // ignore: avoid_print
    print('P0b|阴性对照 pump(无状态变化) => ${neg}us');
    expect(neg, lessThan(50000),
        reason: '静置帧不该花 50ms 以上');

    // 阳性：build 里同步忙等 200ms
    k.currentState!.bump(block: 200);
    final pos = await _pumpMicros(t);
    // ignore: avoid_print
    print('P0b|阳性对照 build 忙等 200ms => ${pos}us '
        '(要求 >=150000us)');
    expect(pos, greaterThanOrEqualTo(150000),
        reason: '★★★ 仪器读不出 200ms 阻塞 ⇒ 仪器不可信 ⇒ '
            '后面所有"不卡"的读数一律作废（铁律：没有阳性对照的空通过）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  PA 搜索页：N 次流式 hit ⇒ 重建面 + 墙钟
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('PA 搜索页：20 次流式 hit ⇒ 重建面 / 墙钟 是否随命中数增长', (t) async {
    await sizeView(t, _size);
    await t.pumpWidget(host(const SearchPage(), _size));
    await t.pump();
    _claim(t);

    final st = t.state<SearchPageState>(find.byType(SearchPage));
    st.debugSetProviderCount(4);
    st.debugBeginSearch('测试');
    await t.pump();
    _claim(t);

    /*
     * ★ 前置（判别力前提）：结果区必须**真的**渲染了。
     *
     * `_totalProviders == 0` 会挡住整个结果区（`search_page.dart:372-379`），
     * 而 `flutter test` 里 `listProviders()` 必抛 ⇒ 不注入的话
     * 下面所有"重建面"读数都是对**空树**的读数（铁律 149）。
     */
    expect(find.textContaining('当前没有支持搜索的内容源'), findsNothing,
        reason: '★ 前置不成立：结果区被 `_totalProviders == 0` 挡住了 '
            '⇒ 下面的读数全是空树的读数');

    const hits = 20;
    const itemsPerHit = 5;
    final rebuilds = <int>[];
    final micros = <int>[];

    for (var i = 0; i < hits; i++) {
      _install();
      st.debugFeedHit(SearchStreamEvent(
        kind: SearchEventKind.hit,
        provider: 'p$i',
        providerName: '源$i',
        items: [
          for (var j = 0; j < itemsPerHit; j++)
            MediaItem(id: 'p$i:$j', title: '剧名$j'),
        ],
      ));
      micros.add(await _pumpMicros(t));
      rebuilds.add(_all);
      _claim(t);
    }

    // ignore: avoid_print
    print('PA|搜索页 $hits 次 hit（每次 $itemsPerHit 条）'
        ' 重建面: ${_stat(rebuilds)}');
    // ignore: avoid_print
    print('PA|搜索页 $hits 次 hit 墙钟(us): ${_stat(micros)}');
    // ignore: avoid_print
    print('PA|首/末对比: 重建面 ${rebuilds.first} -> ${rebuilds.last}, '
        '墙钟 ${micros.first}us -> ${micros.last}us');

    // 阳性对照：每次 hit 都必须**真的**重建了（否则读数是空的）
    expect(rebuilds.every((n) => n >= 1), isTrue,
        reason: '★ 阳性对照：每次 hit 都必须引发重建 —— '
            '有一次是 0 就说明注入器没送到，读数作废');

    /*
     * ★ 这条盯的是**超线性增长**：
     *   `_addHit` 每次都 `rankHitGroups(keyword, [..._hits, 新组])`
     *   ⇒ 命中越多，每次要重排的列表越长（O(n) / 次 ⇒ O(n²) 总计）。
     *   重建面若也随之线性增长 ⇒ 后面的命中越来越贵。
     *   允许 3 倍余量（布局抖动、缓存冷热都会影响单次读数）。
     */
    expect(rebuilds.last, lessThanOrEqualTo(rebuilds.first * 3 + 50),
        reason: '★★ 重建面随命中数**显著增长** ⇒ 搜索越到后面越卡。'
            '首=${rebuilds.first} 末=${rebuilds.last}');
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  PB 设置页：★ 合成侧**挂不上** —— 这里量的是「为什么挂不上」
  // ═══════════════════════════════════════════════════════════════════════
  //
  // # 实测读数（不是猜的）
  //
  // ```text
  // PB|★ 诊断：ListView=0，CircularProgressIndicator=0
  // PB|★ 关键类型: SettingsPage=1 Scaffold=1 Center=0 ListView=0
  //              Stack=1 ErrorWidget=1 CustomScrollView=0 SingleChildScrollView=0
  // ```
  //
  // `SettingsPage.build()`（`settings_page.dart:1613-1621`）**只有两个出口**：
  // ```dart
  //   if (_loading) return const Center(child: CircularProgressIndicator());
  //   return Stack(children: [ ListView(...), ... ]);
  // ```
  // 而读数里 **Center=0 且 ListView=0** ⇒ 两个出口都没走到
  // ⇒ 只能是 `build()` **抛异常**，被框架换成了 `ErrorWidget`（ErrorWidget=1）。
  //
  // # 抛在哪一行（逐字行号）
  //
  // ```text
  // settings_page.dart:2059   subtitle: '${SourinApi.version} · 架构与设备信息',
  //   → sourin_api.dart:84   static String get version => SourinCore.version;
  //   → ffi.dart:197         static String get version { _ensureBound(); ... }
  //   → ffi.dart:182         static void _ensureBound()
  //   → ffi.dart:169         _lib = DynamicLibrary.open('sourin_core.dll');
  // ⇒ 测试进程里没有这个 DLL ⇒ 抛
  // ```
  //
  // ★ 这一行在 `ListView.children` 里 ⇒ 它一抛，**整个 ListView 元素**
  //   被换成 `ErrorWidget`（所以 `ListView=0` 而不是 `ListView=1`），
  //   而 `Stack`/`Scaffold`/`SettingsPage` 还在（=1）—— 读数形状完全吻合。
  //
  // # ⇒ 因此
  //
  // ```text
  // ❌ 合成侧**无法**给出「设置页滚动 600px 的重建面」读数
  //    —— 页面根本没渲染出来，滚的是空树。
  // ✅ 设置页滚动只能在**真机**上量（`.probe/t74_perf_real_pages.txt`）。
  // ```
  //
  // ★ 本用例**故意**断言「挂不上」这个事实 —— 而不是删掉它或让它跳过。
  //   理由（铁律：一条永远为真的断言比没有断言更危险）：
  //   若哪天有人给设置页补了注入口/兜底，本用例会**变红**，
  //   那时就该把滚动读数补回来，而不是继续报「合成侧量不到」。
  testWidgets('PB 设置页：合成侧挂不上（真因 = 缺 sourin_core.dll）⇒ 必须真机量',
      (t) async {
    await sizeView(t, _size);
    await t.pumpWidget(host(const SettingsPage(), _size));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    final noise = _claimLogged(t);
    if (noise.isNotEmpty) {
      // ignore: avoid_print
      print('PB|环境噪声（前 ${noise.length} 条）: $noise');
    }

    final lv = find.byType(ListView).evaluate().length;
    final cpi = find.byType(CircularProgressIndicator).evaluate().length;
    final ew = find.byType(ErrorWidget).evaluate().length;

    // ignore: avoid_print
    print('PB|设置页：ListView=$lv CircularProgressIndicator=$cpi '
        'ErrorWidget=$ew');
    // ignore: avoid_print
    print('PB|关键类型: ${_countTypes(t, [
          'SettingsPage',
          'Scaffold',
          'Center',
          'ListView',
          'CircularProgressIndicator',
          'Stack',
          'ErrorWidget',
          'CustomScrollView',
          'SingleChildScrollView',
        ])}');
    // ignore: avoid_print
    print('PB|★ 树上类型（前 40）: ${_dumpTypes(t)}');
    // ignore: avoid_print
    print('PB|★ 结论：合成侧量不到设置页滚动 '
        '⇒ 只能真机量（.probe/t74_perf_real_pages.txt）');

    /*
     * ★ 前置（判别力前提）：若**两个出口都不在**而设置页真的渲染出来了
     *   ⇒ 那时本用例的「量不到」结论就是错的，必须改回滚动读数。
     */
    if (lv > 0 || cpi > 0) {
      fail('★ 设置页在合成侧**渲染出来了**'
          '（ListView=$lv CircularProgressIndicator=$cpi）⇒ '
          '本用例「合成侧量不到」的结论已失效，'
          '必须把滚动重建面读数补回来（不要放宽这条断言）');
    }

    expect(ew, greaterThan(0),
        reason: '★ 前置不成立：既没有 ListView/CircularProgressIndicator，'
            '也没有 ErrorWidget ⇒ 页面去哪了？读数无法解释'
            '  噪声=$noise');

    // ★ 真因必须是「缺 DLL」，不能是别的原因（否则本用例在守一个错误的机制）
    final joined = noise.join(' | ');
    expect(joined.contains('sourin_core.dll'), isTrue,
        reason: '★ 真因不是缺 sourin_core.dll ⇒ 设置页挂不上另有原因，'
            '本用例记录的机制是错的，必须重新定位'
            '  噪声=$joined');

    // ★ 收尾：`_flash()` 排了一个 3 秒的 `Future.delayed`
    //   （`settings_page.dart:477`）⇒ 不冲掉就是 "A Timer is still pending"
    await t.pump(const Duration(seconds: 4));
    _claim(t);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  PC 追更页：注入 20 条续播 ⇒ 重建面
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('PC 追更页：注入 20 条续播记录 ⇒ 重建面 / 墙钟', (t) async {
    await sizeView(t, _size);
    await t.pumpWidget(host(const FollowPage(initialTab: 'continue'), _size));
    await t.pump();
    await t.pump();
    _claim(t);

    final st = t.state<FollowPageState>(find.byType(FollowPage));

    const n = 20;
    _install();
    st.debugSetContinueList([for (var i = 0; i < n; i++) mkProgress(i)]);
    final first = await _pumpMicros(t);
    final firstRebuild = _all;
    _claim(t);

    // ignore: avoid_print
    print('PC|追更页注入 $n 条 ⇒ 重建面=$firstRebuild 墙钟=${first}us');

    expect(firstRebuild, greaterThan(0),
        reason: '★ 阳性对照：注入 20 条必须**真的**重建了页面');

    // 再滚一次，看滚动代价
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isNotEmpty) {
      final sc = t.state<ScrollableState>(scrollables.first);
      _install();
      sc.position.jumpTo(200);
      final sc2 = await _pumpMicros(t);
      // ignore: avoid_print
      print('PC|追更页滚动 200px ⇒ 重建面=$_all 墙钟=${sc2}us');
      _claim(t);
    }

    await t.pump(const Duration(seconds: 5));
    _claim(t);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  PD 直播页：挂载 + 失败路径 ⇒ 重建面
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('PD 直播页：挂载 + 无核心 DLL 的失败路径 ⇒ 重建面', (t) async {
    await sizeView(t, _size);
    _install();
    await t.pumpWidget(host(const LivePage(), _size));
    await t.pump();
    final mountRebuild = _all;
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);

    // ignore: avoid_print
    print('PD|直播页挂载 ⇒ 重建面=$mountRebuild（首帧）+ 后续 2 帧');

    /*
     * ★ 如实报告：`flutter test` 里 `getLiveChannels()` 必抛
     *   ⇒ `_groups` 恒为空 ⇒ **没有任何频道** ⇒
     *   `_probeAll()` 里"每个频道都 setState"那条路径**根本走不到**
     *   ⇒ 本文件**无法**给出"48 个频道 = 48 次重建"的读数。
     *   那条只能在真机上量（见 `.probe/t74_perf_real_pages.txt`）。
     */
    // ignore: avoid_print
    print('PD|★ 局限：无核心 DLL ⇒ `_groups` 为空 ⇒ '
        '`_probeAll` 的逐频道 setState 路径走不到，本文件测不到它');

    expect(mountRebuild, greaterThan(0),
        reason: '★ 阳性对照：挂载必须**真的**重建了元素');

    await t.pump(const Duration(seconds: 5));
    _claim(t);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  PE 启动：ShellPage 挂载到稳定 ⇒ 帧数 / 重建面 / 墙钟
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('PE 启动：ShellPage 挂载到稳定 ⇒ 帧数 / 总重建面 / 墙钟', (t) async {
    await sizeView(t, _size);

    _install();
    final sw = Stopwatch()..start();
    await t.pumpWidget(host(ShellPage(key: debugShellKey), _size));
    final firstFrame = sw.elapsedMicroseconds;
    final firstRebuild = _all;
    _claim(t);

    /*
     * 继续 pump 到"稳定"（连续 3 帧没有任何元素重建）。
     * ⚠️ 设上限 —— 真机上启动会有动画/ticker，测试里也可能有
     *    永不停止的 postFrame 链；不许无限等。
     */
    var frames = 1;
    var total = firstRebuild;
    var stable = 0;
    final perFrame = <int>[firstRebuild];
    while (frames < 60 && stable < 3) {
      _install();
      await t.pump(const Duration(milliseconds: 16));
      total += _all;
      perFrame.add(_all);
      frames++;
      stable = _all == 0 ? stable + 1 : 0;
      _claim(t);
    }
    sw.stop();

    // ignore: avoid_print
    print('PE|启动：首帧墙钟=${firstFrame}us 首帧重建面=$firstRebuild');
    // ignore: avoid_print
    print('PE|启动：到稳定共 $frames 帧，总重建面=$total，'
        '总墙钟=${sw.elapsedMicroseconds}us');
    // ignore: avoid_print
    print('PE|启动：逐帧重建面 ${perFrame.take(12).toList()}'
        '${perFrame.length > 12 ? ' …' : ''}');

    expect(firstRebuild, greaterThan(0),
        reason: '★ 阳性对照：首帧必须**真的**建了元素');

    await t.pump(const Duration(seconds: 5));
    _claim(t);
  });
}
