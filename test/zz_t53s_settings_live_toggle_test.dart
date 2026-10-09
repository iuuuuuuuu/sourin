// ═══════════════════════════════════════════════════════════════════════
//  task-53【#4a】设置页 UI 层端到端：设置 → JS 插件 → 直播源 tab → 点启停
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件（task-53 #4a 的**最后一个缺口**）
//
// ```text
// Owner 原话（#4a）：
//   直播 配置源的开启不是上面出现tag点击开关的,是有个配置的地方,
//   可以配置 放在设置页面吧
//
// 已证（FFI 层）：setProviderEnabled('iptv', false) ⇒ 44 → 0；
//                 true ⇒ 44（.probe/t53r_ffi_live.out）
// ★ 没证：**那个界面到底点不点得动** —— FFI 层绿 ≠ UI 层绿。
//   中间的接线（卡片按钮 → _toggleProvider → 写盘 → 读回 → 重载列表）
//   一次都没被驱动过。
// ```
//
// # ★★★ 仪器关键 1：真 FFI 在 `flutter test` 里**能**跑，但要自己把 DLL 载进来
//
// ```text
// 历史上记着 `Failed to load dynamic library 'sourin_core.dll' … (error 126)`
// 被当成「设置页在合成侧挂不上」—— `test/t74_perf_synth_test.dart:412`
// 甚至**故意断言**这个事实（它的注释说：若哪天有人补了注入口，本用例会变红）。
//
// ★ 实测真相：那是 **PATH / loader 搜索问题**。
//   `lib/core/ffi.dart:169` 用的是**裸名** `DynamicLibrary.open('sourin_core.dll')`
//   ⇒ 而测试**没法给自己设 PATH**（必须在进程启动前生效）。
//
// ★ 解法（`.probe/t53t_preload.out` 实测）：先按**绝对路径** open 一次。
//   Windows 加载器规则（LoadLibrary 文档逐字）：
//     「若同名模块已在内存中，系统只查重定向与 manifest 就直接解析到已加载的
//       那个，不管它在哪个目录。**不会再去搜索**。」
//   ⇒ 之后 ffi.dart 的裸名 open 就命中已加载的模块（见 `_preloadCoreDll()`）。
// ```
//
// # ★★★ 仪器关键 2（第一版就是死在这里，挂了整整 10 分钟）
//
// ```text
// `SourinApi.xxx()` 走 `Ffi.callAsync` → Rust 在 tokio worker 线程里干完活，
// 再用 `NativeCallable.listener` **把结果投递成一条 isolate 消息**
// （lib/core/ffi.dart:295-306 逐字记着为什么要 listener：
//  普通 `Pointer.fromFunction` 跨线程调用会直接崩）。
//
// ★ 而 `testWidgets` 的**测试体跑在 FakeAsync zone 里** —— 那个 zone
//   只推进**假时钟**与它自己的微任务队列，**不会处理真实事件循环上的
//   isolate 消息**。
// ⇒ 在测试体里裸写 `await SourinApi.getProviderEnabled(id)` = **永远不返回**。
//
// 第一版实测（`.probe/t53s_settings_toggle.out`）：
//   前面全部正常，走到 `final ffiBefore = await SourinApi.getProviderEnabled(...)`
//   就停住 ⇒ `TimeoutException after 0:10:00.000000: Test timed out after 10 minutes.`
//   ⇒ 进程树看起来"还在跑"，其实一步没走（父 dart.exe CPU = 0.046875s）。
//
// ★ 解法 = **`tester.runAsync()`**：它把回调放进真实事件循环里跑。
//   凡是"我在测试体里直接 await 的真 FFI"一律包进去（`_ffi()`）。
//   ⚠️ 而**由 widget 自己发起**的 FFI（`_toggleProvider` 里的
//   `setProviderEnabled` / `getProviderEnabled` / `loadAll()`）不用包 ——
//   它们由 `onPressed` 在 fake zone 里起，只要我用 `_realWait()` 反复
//   `runAsync` 给真事件循环开窗口 + `pump()` 抽干微任务，就能跑完。
// ```
//
// # 环境前提（不满足就**跳过**，不假装通过）
//
// ```text
// ① `build\windows\x64\runner\Release\sourin_core.dll` 必须存在（要先构建 Windows）
//    ★ 缺了 ⇒ `skip:`（**不是** fail）—— 默认套件不该因为"这台机器没构建
//      Windows 版"而变红。skip 的原因会打在输出里。
// ② 跨页闭环那条**会碰公网**（iptv 源要拉 m3u）⇒ 用**条件断言**：
//    只有"点击前"确实读到了该源的分组才断言，否则记「没测到」。
//    ⇒ 离线时它记「没测到」而**不是变红**，不给默认套件引入假红（铁律 78）。
// ```
//
// # 跑法
//
// ```powershell
// & D:\WishProject\sourin-flutter-spike\.probe\flutter_test_lock.ps1 `
//     -Paths 'test/zz_t53s_settings_live_toggle_test.dart' -Agent add-remote-order
// ```

// ★ 只取 `DynamicLibrary` —— `dart:ffi` 与 `dart:ui` **都导出 `Size`**
//   ⇒ 裸 `import 'dart:ffi';` 会报
//     `'Size' is imported from both 'dart:ffi' and 'dart:ui'`（实测踩到）。
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

const String kTag = '[T53S]';
void log(String s) => debugPrint('$kTag $s');

/// ★ 单个用例的硬超时 —— 一个能静默挂 10 分钟的测试比失败的测试更贵
///   （它看起来像"还在跑"）。第一版就是挂满了默认的 10 分钟。
///
/// ⚠️ 给到 5 分钟而不是 1 分钟：跨页那条读数要拉公网 m3u（可能慢），
///    超时失败会被误读成"产品坏了" ⇒ 宁可给宽。
const Timeout kTimeout = Timeout(Duration(minutes: 5));

/// 交付件里那颗 DLL（`lib/core/ffi.dart:169` 只认**裸名**，所以要我们自己载）
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';

/// ★ 环境前提：DLL 在不在。不在就**跳过**（不是失败）。
final bool _dllReady = File(_dllRel).existsSync();

/// ★★★ 把 DLL 按**绝对路径**载进本进程 ⇒ 之后 `ffi.dart` 的裸名 open 命中它
///
/// 见文件头「仪器关键 1」。**必须在 `SourinApi.start()` 之前**调用。
void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  log('DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

// ═══════════════════════════════════════════════════════════════════════
//  工具
// ═══════════════════════════════════════════════════════════════════════

/// ★ 必须给 `Material` 祖先 —— `SettingsEntryRow` / `_ProviderCard` 的
///   `InkWell` / `TextButton` 都要它（t53p 踩过：缺了会抛
///   `No Material widget found` ⇒ 建树中断 ⇒ 布局成垃圾 ⇒ 读数全废）。
Widget _host(Widget child, {Size size = const Size(1280, 900)}) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(size: size),
          child: Material(
            type: MaterialType.transparency,
            child: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}

/// ★★★ **在测试体里直接 await 真 FFI 的唯一正确姿势**
///
/// 见文件头「仪器关键 2」：`testWidgets` 的测试体在 FakeAsync zone 里，
/// 而 `callAsync` 的结果是靠 `NativeCallable.listener` **投递成 isolate
/// 消息**回来的 —— 假 zone 不处理真实事件循环 ⇒ 裸 await 永不返回。
Future<T> _ffi<T>(WidgetTester tester, Future<T> Function() body) async {
  final r = await tester.runAsync(body);
  return r as T;
}

/// 让**真异步**（FFI 回包）跑 —— 走真时间
Future<void> _realWait(WidgetTester tester, int ms) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
}

/// 给真事件循环开窗口 + 抽干微任务（供 **widget 自己发起**的 FFI 推进）
Future<void> _settle(WidgetTester tester, {int rounds = 8, int ms = 300}) async {
  for (var i = 0; i < rounds; i++) {
    await _realWait(tester, ms);
    await tester.pump();
    _claim(tester, 'settle$i');
  }
}

/// 收走并**记下**异常（不静默：第一条会打出来）
void _claim(WidgetTester tester, String where) {
  var n = 0;
  while (true) {
    final e = tester.takeException();
    if (e == null) break;
    n++;
    if (n <= 2) {
      log('$where| ★ 收走异常: ${e.toString().split('\n').first}');
    }
  }
}

/// ★ 0 命中时返回 null（`find.xxx.first` 自己会抛 `Bad state: No element`）
Finder? _safe(Finder f) {
  try {
    if (f.evaluate().isEmpty) return null;
  } catch (_) {
    return null;
  }
  return f.first;
}

int _count(Finder f) {
  try {
    return f.evaluate().length;
  } catch (_) {
    return -1;
  }
}

String _rect(WidgetTester tester, Finder? f) {
  if (f == null) return '(未找到)';
  final r = tester.getRect(f);
  return 'x=${r.left.toStringAsFixed(1)}..${r.right.toStringAsFixed(1)} '
      'y=${r.top.toStringAsFixed(1)}..${r.bottom.toStringAsFixed(1)} '
      'w=${r.width.toStringAsFixed(1)} h=${r.height.toStringAsFixed(1)}';
}

/// 扫描树上所有 `Text`，找 `N/M 已启用` 那一行（直播源 tab 的汇总读数）
///
/// ★ 为什么不写死 `find.text('2/2 已启用')`：数字取决于隔离 dataDir 里
///   到底有几个 live 源 —— 写死等于把"仪器读数"变成"我的假设"。
class CountReading {
  const CountReading(this.raw, this.enabled, this.total);
  final String raw;
  final int enabled;
  final int total;

  @override
  String toString() => '$raw (enabled=$enabled total=$total)';
}

CountReading? _liveCount(WidgetTester tester) {
  final re = RegExp(r'^(\d+)/(\d+) 已启用$');
  for (final e in find.byType(Text).evaluate()) {
    final t = (e.widget as Text).data;
    if (t == null) continue;
    final m = re.firstMatch(t);
    if (m != null) {
      return CountReading(t, int.parse(m.group(1)!), int.parse(m.group(2)!));
    }
  }
  return null;
}

/// 树上所有 `_ProviderCard` 的**卡片名**（卡片里第一行非空 `Text`）
List<String> _cardNames(WidgetTester tester) {
  final cards = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_ProviderCard',
  );
  final out = <String>[];
  for (final c in cards.evaluate()) {
    String? name;
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null && w.data!.trim().isNotEmpty) {
        name ??= w.data;
      }
      e.visitChildren(visit);
    }

    c.visitChildren(visit);
    out.add(name ?? '(无名)');
  }
  return out;
}

/// 某张源卡片（按源名定位）里的一个按钮
Finder? _cardButton(WidgetTester tester, String providerName, String label) {
  final card = _safe(
    find.ancestor(
      of: find.text(providerName),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_ProviderCard',
      ),
    ),
  );
  if (card == null) return null;
  return _safe(find.descendant(of: card, matching: find.text(label)));
}

/// 树上含某段文字的 `Text`（用于找 toast / 卡片状态）
List<String> _textsContaining(WidgetTester tester, String needle) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final t = (e.widget as Text).data;
    if (t != null && t.contains(needle)) out.add(t);
  }
  return out;
}

/// ★ 直播页的数据源读数：`getLiveChannels()` 按源分组统计
///
/// # 为什么这一条才是"用户真正在乎"的读数
///
/// ```text
/// 只证「按钮写了个标志位」不够 —— 用户要的是"关掉这个直播源"。
/// 而直播页 `loadAll()` 的唯一数据源就是 `SourinApi.getLiveChannels()`
/// （`lib/ui/live_page.dart:867`）⇒ 它按源分组的结果**才是**直播页会看到的东西。
/// ```
///
/// ⚠️ 会碰公网（iptv 源要拉 m3u）⇒ 慢是正常的，不是挂住。
Future<String> _channelsByProvider(WidgetTester tester) async {
  try {
    final g = await _ffi(tester, () => SourinApi.getLiveChannels());
    final parts = <String>[];
    var total = 0;
    for (final x in g) {
      parts.add('${x.provider}=${x.channels.length}');
      total += x.channels.length;
    }
    return '分组=${g.length} 总频道=$total [${parts.join(", ")}]';
  } catch (e) {
    return '★ getLiveChannels 失败: $e';
  }
}

/// 走一遍「一级页 → 点 JS 插件 → 点直播源 tab」的导航（两处测试共用）
Future<bool> _navToLiveTab(WidgetTester tester, String tag) async {
  final entry = _safe(find.text('JS 插件'));
  if (entry == null) {
    log('$tag| ★★ 一级页没找到「JS 插件」入口 ⇒ 后续读数全部无效');
    return false;
  }
  log('$tag| 一级页「JS 插件」文本命中 = ${_count(find.text('JS 插件'))}');
  log('$tag| 入口行矩形 = ${_rect(tester, entry)}');
  await tester.ensureVisible(entry);
  await tester.pump();
  log('$tag| ensureVisible 后矩形 = ${_rect(tester, entry)}');
  await tester.tap(entry, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  _claim(tester, '$tag|nav');
  log('$tag| 二级页副标题命中 = '
      '${_count(find.textContaining('个内容源'))}');

  log('$tag| 切之前「直播源」文本命中 = ${_count(find.text('直播源'))}');
  final tab = _safe(find.text('直播源'));
  if (tab == null) {
    log('$tag| ★★ 没找到「直播源」tab ⇒ 二级页没进去或 tab 条没渲染');
    return false;
  }
  log('$tag| tab 矩形 = ${_rect(tester, tab)}');
  await tester.tap(tab, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  _claim(tester, '$tag|tab');
  log('$tag| 切之后「直播源」文本命中 = ${_count(find.text('直播源'))}');
  return true;
}

// ═══════════════════════════════════════════════════════════════════════

void main() {
  final dataDir = Directory('.probe/t53s_data');

  late List<ProviderManifest> liveBefore;
  late List<ProviderManifest> allBefore;

  setUpAll(() async {
    // ★ 环境前提不成立 ⇒ 直接返回（两个用例都带 `skip:`，不会真跑）
    if (!_dllReady) {
      log('★★ $_dllRel 不存在 ⇒ 跳过（先构建 Windows 版再跑本守卫）');
      return;
    }

    _preloadCoreDll();

    // ★ 每次跑前删净 ⇒ 绝不碰 Owner 的真实 profile
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    dataDir.createSync(recursive: true);
    final started = await SourinApi.start(dataDir.absolute.path);
    log('start() = $started');

    // ── 前置：`loadAll()` 那六条命令在隔离环境里**逐条**能不能过 ──
    // ★ 若其中任何一条必抛，`loadAll()` 会进 catch ⇒ `_providers` 不更新
    //   ⇒ 我的"文案变了"读数会**因为仪器前提不成立**而变红 —— 那不是产品坏。
    //   所以先单独探一遍，把环境前提摆到明面上。
    // ★ 这里**不在** fake zone（setUpAll 在测试体外）⇒ 可以裸 await。
    try {
      allBefore = await SourinApi.listProviders();
      log('listProviders() = ${allBefore.length} 个');
      for (final p in allBefore) {
        log('   源 ${p.id} / ${p.name} / kind=${p.kind} '
            'enabled=${p.enabled} live=${p.capabilities.live}');
      }
      liveBefore = allBefore.where((p) => p.capabilities.live).toList();
      log('★ capabilities.live 的源 = ${liveBefore.length} 个 '
          '(${liveBefore.map((p) => p.id).join(", ")})');
    } catch (e) {
      log('★ listProviders() 失败: $e');
    }
    try {
      final pl = await SourinApi.listPlugins();
      log('listPlugins() = ok（plugins=${pl.plugins.length} '
          'failed=${pl.failed.length}）');
    } catch (e) {
      log('★ listPlugins() 失败: $e');
    }
    try {
      final r = await SourinApi.remoteStatus();
      log('remoteStatus() = ok（running=${r.running} port=${r.port}）');
    } catch (e) {
      log('★ remoteStatus() 失败: $e');
    }
    try {
      log('remoteAutoStart() = ${await SourinApi.remoteAutoStart()}');
    } catch (e) {
      log('★ remoteAutoStart() 失败: $e');
    }
    try {
      log('listSkipMarkers() = ${(await SourinApi.listSkipMarkers()).length} 条');
    } catch (e) {
      log('★ listSkipMarkers() 失败: $e');
    }
    try {
      log('listPluginSources() = ${(await SourinApi.listPluginSources()).length} 条');
    } catch (e) {
      log('★ listPluginSources() 失败: $e');
    }
  });

  tearDownAll(() {
    if (dataDir.existsSync()) {
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ═══════════════════════════════════════════════════════════════════

  testWidgets('A. 设置页 → JS 插件 → 直播源 tab → 点「停用」→ 读数真的变',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(const SettingsPage()));
    _claim(tester, 'A|pump1');
    await tester.pump();
    _claim(tester, 'A|pump2');

    // 首屏：`_loading = true` ⇒ 转圈；postFrameCallback 已把 loadAll() 发出
    log('A| 首屏 CircularProgressIndicator = '
        '${_count(find.byType(CircularProgressIndicator))}');

    await _settle(tester);
    log('A| 加载后 CircularProgressIndicator = '
        '${_count(find.byType(CircularProgressIndicator))}');
    log('A| 加载后 ListView = ${_count(find.byType(ListView))}');
    log('A| ErrorWidget = ${_count(find.byType(ErrorWidget))}');

    if (!await _navToLiveTab(tester, 'A')) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      return;
    }

    log('A| 切之后空态「还没有支持直播的源」= '
        '${_count(find.text('还没有支持直播的源'))}');
    log('A| 卡片名 = ${_cardNames(tester)}');
    log('A| ★ 汇总读数 = ${_liveCount(tester) ?? "(没找到 `N/M 已启用`)"}');

    // ── ★ 真点「停用」──
    final target = liveBefore.isEmpty ? null : liveBefore.first;
    if (target == null) {
      log('A| ★★ 隔离环境里没有 live 源 ⇒ 按钮测不到（如实记「没测到」）');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      return;
    }
    final other = liveBefore.length > 1 ? liveBefore[1] : null;
    log('A| 目标源 = ${target.id} / ${target.name}（enabled=${target.enabled}）'
        '${other == null ? "" : "  对照源 = ${other.id}"}');

    final btn = _cardButton(tester, target.name, '停用');
    log('A| 「停用」按钮命中 = ${btn == null ? "缺" : "有"}'
        '${btn == null ? "" : "  矩形 = ${_rect(tester, btn)}"}');
    if (btn == null) {
      log('A| ★★ 卡片上没有「停用」按钮 ⇒ 测不到（不是"按钮坏了"）');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      return;
    }

    // ★★ 测试体里的真 FFI 一律过 `_ffi()`（见文件头「仪器关键 2」）
    final ffiBefore =
        await _ffi(tester, () => SourinApi.getProviderEnabled(target.id));
    final otherBefore = other == null
        ? null
        : await _ffi(tester, () => SourinApi.getProviderEnabled(other.id));
    final uiBefore = _liveCount(tester);
    log('A| ── 点击前 ── FFI(${target.id})=$ffiBefore  '
        'FFI(${other?.id ?? "-"})=$otherBefore  UI=$uiBefore');

    // ★★★ 跨页闭环：设置页这一下点下去，**直播页的数据源**到底变没变
    //
    // ```text
    // 只证「按钮写了个标志位」还不够 —— 用户要的是"关掉这个直播源"。
    // 真正有意义的是：`getLiveChannels()`（= 直播页 `loadAll()` 的唯一数据源，
    // `live_page.dart:867`）返回的频道数**真的少掉那个源的**。
    // ```
    final chBefore = await _channelsByProvider(tester);
    log('A| ── 点击前频道 ── $chBefore');

    await tester.ensureVisible(btn);
    await tester.pump();
    await tester.tap(btn, warnIfMissed: false);
    await tester.pump(); // 起异步 _toggleProvider
    await _settle(tester, rounds: 12);

    final ffiAfter =
        await _ffi(tester, () => SourinApi.getProviderEnabled(target.id));
    final otherAfter = other == null
        ? null
        : await _ffi(tester, () => SourinApi.getProviderEnabled(other.id));
    final uiAfter = _liveCount(tester);
    log('A| ── 点击后 ── FFI(${target.id})=$ffiAfter  '
        'FFI(${other?.id ?? "-"})=$otherAfter  UI=$uiAfter');
    log('A| 点后卡片名 = ${_cardNames(tester)}');
    log('A| 点后「启用」按钮 = '
        '${_cardButton(tester, target.name, '启用') == null ? "缺" : "有"}  '
        '「停用」按钮 = '
        '${_cardButton(tester, target.name, '停用') == null ? "缺" : "有"}');
    // ★ 独立信号：toast 证明 `onPressed` **真的被调用**（排除"tap 打偏了"）
    final toast = _textsContaining(tester, '「${target.name}」');
    log('A| ★ toast（含源名的文本）= $toast');
    final chAfter = await _channelsByProvider(tester);
    log('A| ── 点击后频道 ── $chAfter');

    // ── ④ 再点「启用」⇒ 回到原样 ──
    final btnBack = _cardButton(tester, target.name, '启用');
    bool? ffiBack;
    CountReading? uiBack;
    if (btnBack == null) {
      log('A| ★★ 点后没出现「启用」按钮 ⇒ 无法做回程');
    } else {
      await tester.ensureVisible(btnBack);
      await tester.pump();
      await tester.tap(btnBack, warnIfMissed: false);
      await tester.pump();
      await _settle(tester, rounds: 12);
      ffiBack =
          await _ffi(tester, () => SourinApi.getProviderEnabled(target.id));
      uiBack = _liveCount(tester);
      log('A| ── 回程 ── FFI(${target.id})=$ffiBack  UI=$uiBack');
      expect(ffiBack, ffiBefore, reason: '★ 再点「启用」必须回到原状态');
      expect(uiBack?.enabled, uiBefore?.enabled,
          reason: '★ 回程后 UI 汇总读数必须回到原值');
    }

    // ── ★ 硬判据（只有真拿到读数才断言，见文件头"铁律 78"）──
    if (ffiBefore && uiBefore != null && uiAfter != null) {
      expect(ffiAfter, isFalse, reason: '★ 点了「停用」⇒ 真 FFI 必须变 false');
      expect(uiAfter.enabled, uiBefore.enabled - 1,
          reason: '★ 点了「停用」⇒ `N/M 已启用` 的 N 必须少 1');
      expect(uiAfter.total, uiBefore.total, reason: '分母（直播源总数）不该变');
      if (other != null) {
        expect(otherAfter, otherBefore,
            reason: '★ 另一个直播源不该受影响（不是"全表乱动"）');
      }
      // ★★★ 跨页闭环：直播页的数据源里，被停用那个源的频道必须消失
      //
      // ⚠️ 这一条**依赖公网**（iptv 源要拉 m3u）。若"停用前"就读不到那个
      //    分组（公网抽风 / 限流），那**不是**"停用没生效"—— 是没测到。
      //    ⇒ 用阳性对照把它分开，绝不让"没测到"伪装成"坏了"（铁律 78）。
      //    ★ 离线环境下走 else 分支 ⇒ 记「没测到」而**不是**变红。
      if (chBefore.contains('${target.id}=')) {
        expect(chAfter.contains('${target.id}='), isFalse,
            reason: '★ 停用后 `getLiveChannels()` 不该再返回该源的分组');
      } else {
        log('A| ★★ 停用前 `getLiveChannels()` 就没有「${target.id}」分组 '
            '（公网拉取失败/限流）⇒ 跨页闭环**没测到**，不断言');
      }
    } else {
      log('A| ★★ 前置不满足（FFI 初始=false 或没拿到 UI 读数）⇒ 没测到，不断言');
    }

    // ── 收尾：先拆树再推长时长（排掉 `_flash` 的 3 秒一次性 Timer）──
    await tester.pumpWidget(const SizedBox.shrink());
    _claim(tester, 'A|teardown');
    await tester.pump(const Duration(seconds: 5));
    _claim(tester, 'A|teardown');
  },
      // ★ `skip:` 只收 `bool?`（不收原因字符串）—— 原因由 setUpAll 的日志交代
      timeout: kTimeout,
      skip: !_dllReady);

  // ═══════════════════════════════════════════════════════════════════

  testWidgets('B. 反向对照：不点按钮时读数**一个都不变**', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(const SettingsPage()));
    await tester.pump();
    await _settle(tester);

    if (!await _navToLiveTab(tester, 'B')) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      return;
    }

    final before = _liveCount(tester);
    final ffiA = liveBefore.isEmpty
        ? null
        : await _ffi(tester, () => SourinApi.getProviderEnabled(liveBefore.first.id));
    log('B| 起点 UI=$before FFI=${liveBefore.isEmpty ? "-" : ffiA}');

    // ★ 什么都不点，只给同样的真时间（排掉"时间流逝本身会改状态"）
    await _settle(tester, rounds: 12);

    final after = _liveCount(tester);
    final ffiB = liveBefore.isEmpty
        ? null
        : await _ffi(tester, () => SourinApi.getProviderEnabled(liveBefore.first.id));
    log('B| 终点 UI=$after FFI=$ffiB');
    log('B| ★ 变化 = UI ${before?.raw} → ${after?.raw}；FFI $ffiA → $ffiB');

    if (before != null && after != null) {
      expect(after.raw, before.raw, reason: '★ 不点按钮 ⇒ 文案不该自己变');
    }
    if (ffiA != null) {
      expect(ffiB, ffiA, reason: '★ 不点按钮 ⇒ FFI 状态不该自己变');
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    _claim(tester, 'B|teardown');
  },
      // ★ 同 A：`skip:` 只收 `bool?`
      timeout: kTimeout,
      skip: !_dllReady);
}
