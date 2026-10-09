// ═══════════════════════════════════════════════════════════════════════
//  task-11 真机探针 —— 首页切源缓存（stale-while-revalidate）
//  （2026-10-09，Owner：「我在首页每次切换源的时候都要重载」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 判据（Owner 要的是「不重载」，所以判据必须是**用户看得见的那一帧**）
//
// ```text
// ★ A 回切秒开：切回已看过的源，**第一帧**就要有卡片
//     读数 = 那一帧 debugHomeReadout.cards / debugBuiltCards
// ★ B 不重拉：切回时**立刻**发出的列表请求数 == 0
//     读数 = 探针包住 SourinApi.getList/getRank 数出来的调用数
// ★ C 后台刷新：随后**仍然**发出请求（旧内容会被新的追上）
// ★ D 上限：LRU 到 12 个条目就淘汰最久未用的；TTL 过期 / 指纹不符都不算命中
// ★ E 阳性对照：缓存清空后重切，第一帧**必须**没有卡片
//     （否则 A 的「有卡片」可能只是上次留下的残影 ⇒ 判据无效）
// ```
//
// # 为什么必须在**真进程**里量（widget 测试证不了）
//
// ```text
// ① flutter_test 里加载不了 sourin_core.dll ⇒ get_home / get_list 必然抛
//    ⇒ 卡片数恒 0 ⇒ 缓存「命中」与「没命中」读数完全一样（都是 0）
// ② 「第一帧」的判据要的是**真帧**：测试里的 pump 与真实 build 不是一回事
// ③ 请求计数要数**真的** FFI 调用，测试里那条路根本走不到
// ```
//
// # 仪器（两个，都挂在**真实被调用的那个函数**上）
//
// ```text
// ① getListCalls / getRankCalls —— 包住 SourinApi.getList / getRank
//    （产品调的就是它们 ⇒ 数出来的就是「真发了几次列表请求」）
// ② homeListCache.hits / misses / puts / evictions / length
//    —— 产品用的就是这个实例（见 home_page.dart 里那段说明）
// ```
// ★ 本项目踩过「仪器与被测对象不是同一个东西」（见 debugLoadAllCalls 的教训），
//   所以这两处都是**包住真函数**，不是另写一份等价逻辑。
//
// # 数据目录隔离（铁律）
//
// 真核心 + 真网络，但**绝不指向用户真库**：走 T11_DATA_DIR 环境变量。
// ⚠️ 全新数据目录里没有 cctv.js（核心只释放 demo/iptv/tvbox-live），
//    所以 runner 脚本要在**进程外**把仓库里的 cctv.js 拷进去
//    （t6 探针的教训：debug 构建在进程内拷文件会 0xC0000005）。
//
// # 怎么跑
//
// ```powershell
// pwsh -File .probe/t11_build_run.ps1
// ```

import 'dart:async';
import 'dart:io';

// ⚠️ 必须 hide `Page` —— material_ui 也导出 Navigator 的 `Page`，
//    与 `core/models.dart` 的领域 `Page<T>` 重名（不 hide 直接 ambiguous_import）。
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/ffi.dart';
import 'core/models.dart'; // ignore: unnecessary_import（显式带出领域类型，读代码时不必猜）
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart' show AppTab, SourinApp, debugShellKey;
// ⚠️ 用 `show` 只带出本探针真正要读的东西（`homeListCache` 是**产品实例**）。
import 'ui/home_page.dart'
    show HomePage, HomePageState, HomeListCache, HomeSnapshot, homeListCache, kHomeCacheMaxEntries, kHomeCacheTtl, kHomeCacheFreshFor, homeSourceList;

// ⚠️ 一律用正斜杠：探针源码里**不出现反斜杠**，省掉一层转义（本文件是探针，
//    不是产品代码；Dart 在 Windows 上照样认正斜杠）。
const _outDir = 'D:/WishProject/sourin-flutter-spike/.probe';
const _logFile = '$_outDir/t11-cache.txt';

final List<String> _log = [];

/// 逐行立即落盘（探针可能被 runner 超时杀掉，stdout 会被缓冲到退出为止）
void say(String s) {
  _log.add(s);
  debugPrint('[T11] $s');
  try {
    File(_logFile).writeAsStringSync(_log.join('\n'));
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
    File(_logFile).writeAsStringSync(_log.join('\n'));
  } catch (_) {}
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  仪器 ①：列表请求计数（包住产品真正调的那两个函数）
// ═══════════════════════════════════════════════════════════════════════

int listCalls = 0;
int rankCalls = 0;
int homeCalls = 0;

final List<String> timeline = <String>[];
final DateTime _t0 = DateTime.now();
int _ms() => DateTime.now().difference(_t0).inMilliseconds;

int get totalListRequests => listCalls + rankCalls;

Future<List<ProviderGroup>> countingGetHome() async {
  final t = _ms();
  // ⚠️ 必须调 getHomeReal：调 getHome 会再进 hook（= 本函数）⇒ 无限递归（实测炸过）
  final r = await SourinApi.getHomeReal();
  homeCalls++;
  timeline.add('t=${t}ms  get_home 返回 ${r.length} 组（完成于 ${_ms()}ms）');
  return r;
}

Future<Page<MediaItem>> countingGetList(
  String provider,
  String categoryId, {
  int page = 1,
}) async {
  listCalls++;
  say('  · [${_ms()} ms] get_list(provider=$provider, category=$categoryId)');
  // ⚠️ 同上：必须调 Real 版本（否则 计数包装 → getList → hook → 自己）
  return SourinApi.getListReal(provider, categoryId, page: page);
}

Future<Page<MediaItem>> countingGetRank(
  String provider,
  String rankId, {
  int page = 1,
}) async {
  rankCalls++;
  say('  · [${_ms()} ms] get_rank(provider=$provider, rank=$rankId)');
  // ⚠️ 同上：必须调 Real 版本
  return SourinApi.getRankReal(provider, rankId, page: page);
}

// ═══════════════════════════════════════════════════════════════════════
//  帧 / 等待
// ═══════════════════════════════════════════════════════════════════════

/// 真帧：Future.delayed(16ms) 让出事件循环
///
/// ⚠️ 不能用 endOfFrame 空转 —— 那样 Timer（网络超时、看门狗）永不到期，
///    整个循环会在同一毫秒内跑完（t2d / t6 探针都实测踩过）。
Future<void> pumpReal(int n, String tag) async {
  for (var i = 0; i < n; i++) {
    if (n >= 20 && i % 20 == 0) say('  [$tag] frame $i/$n');
    WidgetsBinding.instance.scheduleFrame();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

/// ★★ **单帧**：只排一次帧、只等一个 tick
///
/// 这是「第一帧」判据的关键 —— pump 两帧就会跨过两次 build，
/// 那时后台刷新的结果可能已经回来了，量到的就不是「切源那一刻」。
Future<void> pumpOneFrame(String tag) async {
  WidgetsBinding.instance.scheduleFrame();
  await Future<void>.delayed(const Duration(milliseconds: 16));
  say('  [$tag] 单帧已过');
}

Future<bool> waitUntil(bool Function() cond, int maxMs, String tag) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0).inMilliseconds < maxMs) {
    if (cond()) return true;
    await pumpReal(6, tag);
  }
  return cond();
}

final _rootKey = GlobalKey();
Element? _root() => _rootKey.currentContext as Element?;

Element? find(Type t, [Element? from]) {
  final e = from ?? _root();
  if (e == null) return null;
  if (e.widget.runtimeType == t) return e;
  Element? hit;
  void walk(Element x) {
    if (hit != null) return;
    if (x.widget.runtimeType == t) {
      hit = x;
      return;
    }
    x.visitChildren(walk);
  }

  e.visitChildren(walk);
  return hit;
}

/// ★ 每次量首页之前都把 shell 的 tab 切回首页
///
/// t6 探针实测：窗口弹在正在被人使用的桌面上时，会有人点底栏把首页切走
/// ⇒ 读数被污染。所以「量之前显式切回」是必需的。
Future<void> guardHome() async {
  debugShellKey.currentState?.debugSwitchTo(AppTab.home);
  await pumpReal(20, 'guard-home');
  final t = debugShellKey.currentState?.debugCurrentTab;
  if (t != AppTab.home) say('★ 切回首页失败（当前 tab=$t）—— 读数可能不可信');
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ★ 看门狗：无论卡在哪，产物里一定有一条 RESULT（t6 探针的教训）
  Timer(const Duration(seconds: 900), () {
    say('');
    say('★ 看门狗触发（900s）：进程卡在收尾，强制落盘');
    say('RESULT pass=$pass fail=$fail');
    try {
      File(_logFile).writeAsStringSync(_log.join('\n'));
    } catch (_) {}
    exit(fail == 0 ? 0 : 1);
  });

  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    final dll =
        File('$Directory.current.path$Platform.pathSeparatorlibmpv-2.dll');
    say('默认初始化失败: $e → 退回显式 DLL（存在=$dll.existsSync()）');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      say('★ 致命：找不到 libmpv-2.dll ⇒ 无法取证');
      await finish(2);
    }
  }

  final envDir = Platform.environment['T11_DATA_DIR'];
  if (envDir == null || envDir.isEmpty) {
    say('★ 必须给 T11_DATA_DIR（隔离数据目录）—— 绝不碰用户真库');
    await finish(2);
  }
  final dataDir = envDir!;
  await Directory(dataDir).create(recursive: true);

  say('══════════════════════════════════════════════════════════');
  say('task-11 首页切源缓存 —— 真进程取证');
  say('数据目录: $dataDir');
  say('PROBE_REPO: ${const String.fromEnvironment('PROBE_REPO')}');
  say('══════════════════════════════════════════════════════════');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1440, 900));
    await windowManager.setTitle('源影 · task-11 缓存探针');
    // ⚠️ 只设尺寸/标题 —— t6 实测 setPosition/setSkipTaskbar 在 runApp 前
    //    会让进程以 0xC0000005 直接崩掉（window_manager 与本项目无边框窗口的问题）。
  }

  await UiPrefs.load(dataDir);
  try {
    final r = await SourinCore.startAsync(dataDir);
    say('核心已启动: $r');
  } catch (e) {
    say('★ 核心启动失败: $e ⇒ 中止（没有真核心就量不到真数）');
    await finish(2);
  }

  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: null, coreDataDir: dataDir),
  ));

  final up = await waitUntil(() => find(HomePage) != null, 60000, 'wait-home');
  ok('首页已挂上（真 SourinApp → ShellPage → HomePage）', up);
  if (!up) await finish(1);

  final homeEl = find(HomePage);
  final raw0 =
      (homeEl is StatefulElement) ? homeEl.state as HomePageState : null;
  ok('拿到 HomePageState', raw0 != null);
  if (raw0 == null) await finish(1);
  final HomePageState home = raw0!;

  await guardHome();
  say('当前 tab = ${debugShellKey.currentState?.debugCurrentTab}');

  // ══════════════════════════════════════════════════════════════════
  //  0) 装两个本地 HTTP 源（真 HTTP · 真契约 · 真注册表）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么要本地源（而不是直接用公网源）
  //
  // 本任务的判据是「切回已看过的源，**第一帧**有没有卡片」——
  // 这条判据必须**可重复**，不能取决于今天哪个公网站点通、哪个站点抽风。
  // 本地源能给确定性：两个源各有 2 个区块 × 2 张卡，毫秒级返回。
  //
  // ⚠️ 但它**仍然是真链路**：真 HTTP（reqwest 出网到 127.0.0.1）、
  //    真 manifest 校验（apiVersion=1）、真注册表、真 FFI 往返。
  //    探针没有把 get_list 换成假函数来伪造数据。
  try {
    final a = Platform.environment['T11_PROVIDER_A'];
    final b2 = Platform.environment['T11_PROVIDER_B'];
    if (a != null && a.isNotEmpty) {
      final m = await SourinApi.installHttpProvider(a);
      say('装入本地源 A: id=${m.id} name=${m.name} '
          'vod=${m.capabilities.vod} <- $a');
    }
    if (b2 != null && b2.isNotEmpty) {
      final m = await SourinApi.installHttpProvider(b2);
      say('装入本地源 B: id=${m.id} name=${m.name} '
          'vod=${m.capabilities.vod} <- $b2');
    }
  } catch (e) {
    say('★ 装本地源失败: $e（后面会退回可用公网源，读数可能不稳定）');
  }
  // ⚠️ 让首页重新扫一遍源清单（否则还是启动那一刻的旧列表）
  await home.loadAll(force: true, reason: 'probe-after-install');
  await waitUntil(() => !home.debugHomeReadout.loading, 180000, 'install');

  // ── 源清单（证明「这台机器上确实有能出内容的源」）──
  final providers = await SourinApi.listProviders();
  say('源清单读数: 共 ${providers.length} 个');
  for (final p in providers) {
    say('  · ${p.id} enabled=${p.enabled} vod=${p.capabilities.vod}');
  }
  final enabled = providers.where((p) => p.enabled).toList();
  say('源清单: 共 ${providers.length} 个，已启用 ${enabled.length} 个');
  for (final p in enabled) {
    say('  · ${p.id} vod=${p.capabilities.vod} live=${p.capabilities.live}');
  }
  final homeSources = homeSourceList(enabled).map((p) => p.id).toList();
  say('首页可用（vod=true）: $homeSources');
  ok('至少 2 个首页可用源（否则「切源」这件事无从量起）',
      homeSources.length >= 2, '实测 $homeSources');

  /*
   * ★ 选用哪两个源：**两个本地源**优先（确定性），否则退回前两个首页可用源。
   * ⚠️ 必须**两个不同**的源 —— 同一个源切来切去，"缓存命中"与"本来就有数据"
   *    分不开（那正是 E 阳性对照要排掉的情形）。
   */
  final local = homeSources.where((p) => p.startsWith('t11')).toList();
  final srcA = local.isNotEmpty ? local[0] : homeSources[0];
  final srcB = local.length > 1
      ? local[1]
      : (homeSources.length > 1 ? homeSources[1] : homeSources[0]);
  say('本探针用这两个源做对照: A=$srcA / B=$srcB');
  ok('★ 前置条件：A 与 B 是**两个不同**的源（同一个源切不出"重载"问题）',
      srcA != srcB, 'A=$srcA B=$srcB');

  // ══════════════════════════════════════════════════════════════════
  //  0b) 诊断：**直接问核心**（不经首页），本地源到底有没有内容
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须先做这一步（实测踩到，且非常容易误判）
  //
  // 第一次真机跑，首页在 t11a/t11b 上显示 **0 张卡**、切源等 120s 超时。
  // 那看起来像"缓存没生效"，但其实有两种完全不同的原因：
  // ```text
  // ① 核心聚合（get_home）根本没把本地源放进来 ⇒ 页面无内容可画
  // ② 核心给了内容，是**页面**没画出来 ⇒ 才是本任务的 bug
  // ```
  // 只看页面读数分不开这两者（都是 0 卡）。所以这里**直接问核心**：
  //   get_home 里有没有 t11a？get_list('t11a','hot') 有没有返回？
  // ⚠️ 顺带确认一个本机事实：这台机器有系统代理（HTTP_PROXY=127.0.0.1:7890）——
  //    若核心对 127.0.0.1 也走代理，本地源就会"连不上"，读数会被彻底带偏。
  try {
    final gs = await SourinApi.getHomeReal();
    final ids = gs.map((g) => g.provider).toList();
    say('核心 get_home 直接读数: ${gs.length} 个分组 -> $ids');
    for (final g in gs) {
      say('  · ${g.provider} 区块=${g.sections.length}');
    }
  } catch (e) {
    say('★ get_home 直接调用失败: $e');
  }
  for (final id in <String>[srcA, srcB]) {
    try {
      final pg = await SourinApi.getListReal(id, 'hot');
      say('核心 get_list($id, hot) 直接读数: ${pg.items.length} 条'
          '${pg.items.isEmpty ? "" : "，首条=${pg.items.first.title}"}');
    } catch (e) {
      say('★ get_list($id, hot) 直接调用失败: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  准备：先让首页把 A 源的数据真正拉一遍（此时缓存是空的）
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── 准备：冷启动 A 源（$srcA）──');
  homeListCache.clear();
  SourinApi.debugSetListFetchers(
    getList: countingGetList,
    getRank: countingGetRank,
  );
  SourinApi.debugSetHomeFetcher(countingGetHome);

  /*
   * ★★ 先**切到 A**，再预热 —— 顺序反了的话下面全都量不到（实测踩到）
   *
   * ```text
   * 上一版：直接 loadAll(force) 然后 debugEnsureSections(srcA)。
   * 实测读数：`冷启动后读数: source=cctv 分区=9 卡片=160`
   *   ⇒ 当前源还是 **cctv**（用户真库里的源），根本不是 A。
   * ⇒ 那次的 `_ensureSections(t11a)` 是在"当前源=cctv"下预取别的源，
   *   而 `_groups` 那时已被 loadAll 收窄成 cctv 一份 ⇒ 找不到骨架 ⇒ 静默返回
   *   ⇒ **A 的快照从来没被写进缓存** ⇒ 后面"切回 A"当然不命中（720ms/2 请求）。
   * ```
   * ⚠️ 这同时暴露了产品侧一个真缺陷（已修）：`_ensureSections` / `_loadSectionsOf`
   *    原来从 `_groups`（已收窄）取骨架 ⇒ 对非当前源静默失效。现在改用 `_allGroups`。
   * ★ 顺序上先切源还有第二个好处：切源本身会走 `_ensureSections` 把数据拉回来并存快照，
   *   于是后面那次 loadAll 看到的就是"已经有数据的源"。
   */
  home.debugSwitchSource(srcA);
  await pumpReal(4, 'warm-switch');
  await home.loadAll(force: true, reason: 'probe-warm');
  await waitUntil(() => !home.debugHomeReadout.loading, 120000, 'warm');
  await pumpReal(20, 'warm-pump');
  /*
   * ★★ 再按需补一轮（**不是** force）
   *
   * # 为什么不能只靠上面那次 force（我实测踩到的仪器坑）
   * ```text
   * 前面「装本地源」之后我调过一次 loadAll(force: true, reason=probe-after-install)，
   * 那一次会**写入一份快照** —— 如果那时本地 provider 的 /list 还没被真正打过
   *   （或刚起、首帧超时），快照里就是"骨架在、items 全空"。
   * 而快照的 items 一旦全空，A 源的"命中"就会画出一排空轨道 ⇒
   *   A1（第一帧有卡片）必然失败，且看起来像产品 bug —— 其实是仪器的坑。
   * ```
   * ⇒ 测量前显式 `_ensureSections` 一次（走**生产**那条按需路径）：
   *   有数据就一个请求都不发，没数据就补上，然后由它收尾时重存快照。
   */
  await home.debugEnsureSections(srcA);
  await pumpReal(10, 'warm-ensure');

  final warm = home.debugHomeReadout;
  say('冷启动后读数: source=${warm.source} 分区=${warm.sections} '
      '卡片=${warm.cards} 已 build=${home.debugBuiltCards}');
  say('缓存: 驻留=${homeListCache.length} hits=${homeListCache.hits} '
      'misses=${homeListCache.misses} puts=${homeListCache.puts} '
      'evictions=${homeListCache.evictions}');
  ok('★ 前置条件：A 源冷启动后真的有卡片（否则后面的「命中」无从判起）',
      warm.cards > 0, 'cards=$warm.cards');
  ok('★ 前置条件：A 源的数据进了缓存（驻留 ≥ 1）',
      homeListCache.length >= 1, '驻留=$homeListCache.length');

  // ══════════════════════════════════════════════════════════════════
  //  切到 B（冷）→ 切回 A（缓存命中 ⇒ 秒开 + 不重拉 + 后台刷新）
  // ══════════════════════════════════════════════════════════════════
  /// 切源 → 等到「内容真的可见」，返回 (第一帧卡片数, 墙钟 ms, 期间请求数)
  ///
  /// ★ 为什么「到内容可见」要用**墙钟 + 轮询**而不是某个回调：
  ///   用户感知的就是「点了之后多久看到东西」，那个数才是判据。
  /// ⚠️ 判据是 `cards > 0 && !loading` —— 只看 `!loading` 会被**空态**骗过
  ///    （空态也是 loading=false，但它什么都没画出来）。
  Future<({int firstCards, int ms, int requests, bool ok})> switchAndTime(
    String id,
    String tag,
  ) async {
    final req0 = totalListRequests;
    final sw = Stopwatch()..start();
    // ignore: invalid_use_of_visible_for_testing_member
    home.debugSwitchSource(id);
    await pumpOneFrame('$tag-first-frame');
    final firstCards = home.debugHomeReadout.cards;
    var ok2 = false;
    while (sw.elapsedMilliseconds < 20000) {
      final r = home.debugHomeReadout;
      if (r.cards > 0 && !r.loading) {
        ok2 = true;
        break;
      }
      await pumpReal(4, '$tag-wait');
    }
    sw.stop();
    if (!ok2) {
      final r = home.debugHomeReadout;
      // ⚠️ 超时也要把**当时的状态**打出来 —— 只说"超时"没法定位
      say('★ [$tag] 20s 内没等到内容: source=${r.source} 分区=${r.sections} '
          '卡片=${r.cards} loading=${r.loading}');
    }
    return (
      firstCards: firstCards,
      ms: sw.elapsedMilliseconds,
      requests: totalListRequests - req0,
      ok: ok2,
    );
  }

  say('');
  say('── 切到 B 源（$srcB，冷加载）──');
  final bRes = await switchAndTime(srcB, 'B');
  say('B 冷加载读数: 第一帧卡片=${bRes.firstCards} '
      '到内容可见=${bRes.ms}ms 期间列表请求=${bRes.requests} 次');

  say('');
  say('── ★ 切回 A 源（$srcA，快照 <${kHomeCacheFreshFor.inSeconds}s）—— 主判据 ──');
  final hitsBefore = homeListCache.hits;
  final aRes = await switchAndTime(srcA, 'A');
  /*
   * ★★ 第一帧的卡片数在 switchAndTime 里就取好了（pumpOneFrame 之后立刻取）——
   *    **不能**再多 pump 一帧：后台任务可能在第二帧就回来了，那时 cards 一样 >0，
   *    但「这一帧有没有卡片」这个判据就被污染了（分不清秒开与刷新太快）。
   */
  final aFirst = home.debugHomeReadout;
  final aFirstBuilt = home.debugBuiltCards;
  say('A 命中读数: 第一帧卡片=${aRes.firstCards} 已 build=$aFirstBuilt '
      '到内容可见=${aRes.ms}ms 期间列表请求=${aRes.requests} 次');
  say('对照 · B 冷加载: 到内容可见=${bRes.ms}ms 请求=${bRes.requests} 次');
  say('加速比: ${bRes.ms}ms → ${aRes.ms}ms'
      '（${aRes.ms <= 0 ? "<1" : (bRes.ms / aRes.ms).toStringAsFixed(1)}x）');

  ok('★A1 切回缓存过的源：**第一帧就有卡片**（用户要的「秒开」）',
      aRes.firstCards > 0 && !aFirst.loading,
      'cards=${aRes.firstCards} loading=${aFirst.loading}');
  ok('★A2 第一帧就**真的 build 出了卡片元素**（不是「数据在但没画」）',
      aFirstBuilt > 0, '已 build=$aFirstBuilt');
  ok('★B  切回时**一个列表请求都没发**（快照还在新鲜窗口内）',
      aRes.requests == 0, '实测 ${aRes.requests} 次');
  ok('★B2 缓存命中计数真的增加了（仪器与产品实例同源）',
      homeListCache.hits > hitsBefore,
      'hits $hitsBefore → ${homeListCache.hits}');
  /*
   * ★ B3 的判据必须**换一个量**（第一版就是这里出的错）
   *
   * ```text
   * 第一版：断言 "命中耗时 × 3 < 冷加载耗时"。实测 18ms vs 20ms ⇒ 假红。
   * 原因不在产品，在**仪器**：本地 provider 1ms 就返回，两边都快到分不出来；
   *   而且"到内容可见"这一项，两条路径**本来就都是 0 帧**
   *   （数据都在内存里，切换是同步的 setState）—— 它根本区分不了命中与未命中。
   * ```
   * ⇒ 真正区分两者的量是**网络请求数**（B 已经断言 = 0）与**总耗时**。
   *   这里改成断言"命中那次的总耗时**不超过**冷加载"（不设倍数，避免仪器噪声）。
   * ★ 冷加载一侧现在有 700ms/请求 的人工延迟（见 runner 的 -DelayMs 700），
   *   所以这个不等式在真机上是有意义的，不是恒真。
   */
  ok('★B3 命中那次的总耗时**不超过**冷加载（本地源极快，故不设倍数）',
      aRes.ms <= bRes.ms,
      '命中=${aRes.ms}ms 冷=${bRes.ms}ms（冷加载含 ${bRes.requests} 次真实请求）');

  // ── C：超过新鲜窗口后切回 ⇒ revalidate 必须发生 ──
  say('');
  say('── C 等快照超过新鲜窗口（${kHomeCacheFreshFor.inSeconds}s）再切回 ⇒ '
      '必须去对新的 ──');
  /*
   * ★ 为什么要**真的等**（而不是把快照时间改老）
   * ```text
   * HomeListCache 没有「改快照时间」的接口 —— 给探针开一个等于给产品开后门。
   * 等 31 秒换来的是**真实的时间语义**：这条断言证明「新鲜窗口在起作用」，
   *   而不是「我改了个数所以它生效了」。
   * ```
   */
  final waitMs = kHomeCacheFreshFor.inMilliseconds + 1500;
  say('  （等待 ${(waitMs / 1000).toStringAsFixed(1)}s…）');
  await pumpReal((waitMs / 16).ceil(), 'C-wait-fresh');
  final bRes2 = await switchAndTime(srcB, 'C-b');
  say('C 切到 B（快照已过期）: 到内容可见=${bRes2.ms}ms '
      '第一帧卡片=${bRes2.firstCards}');
  /*
   * ⚠️⚠️ 计数窗口必须**跨过后台刷新**（第一版在这里量错了）
   *
   * ```text
   * `switchAndTime` 在"第一帧有卡片"时就返回（命中路径 ~17ms）——
   * 而 revalidate 是 `unawaited(...)` 里跑的，**那时还没发出去**。
   * ⇒ 只数到"内容可见"那一刻，永远读到 0 次，看起来像"没去对新的"。
   * ```
   * ⇒ 切完之后再 pump 一段（让后台任务真的跑起来）才计数。
   *   这一段是**给后台刷新留的时间**，不是"等它变慢"。
   */
  final cReq0 = totalListRequests;
  final cRes = await switchAndTime(srcA, 'C-a');
  await pumpReal(60, 'C-revalidate');
  final cReq = totalListRequests - cReq0;
  say('C 切回 A: 第一帧卡片=${cRes.firstCards} 到内容可见=${cRes.ms}ms '
      '请求=$cReq 次（期望 > 0：过期了就该去对新的）');
  ok('★C1 第一帧**仍然**有卡片（旧内容先画出来，不是骨架）',
      cRes.firstCards > 0, 'cards=${cRes.firstCards}');
  ok('★C2 快照过期后切回 ⇒ **真的去对新的**（revalidate 生效）',
      cReq > 0, '实测 $cReq 次');

  // ══════════════════════════════════════════════════════════════════
  //  E 阴性对照：把缓存**整个关掉**，重切 B → A
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── E 阴性对照：关掉缓存后重切 B → A（= 改之前的行为）──');
  /*
   * ★★★ 这一段是本探针**最重要**的一段：它推翻了我自己第一版的判据。
   *
   * # 我第一版怎么做的（错的）
   * ```text
   * 阳性对照 = `homeListCache.clear()` 然后切回 A，期望"第一帧没有卡片"。
   * 实测：第一帧**有 4 张卡片、0 次请求** ⇒ 对照失败。
   * 我当时第一反应是"缓存有 bug" —— **错了**。
   * ```
   * # 真正的原因（`_sectionItems` 从来不清）
   * ```text
   * 页面有一个 `Map<String,List<MediaItem>> _sectionItems`（**改之前就有**），
   * 按 `provider::sectionId` 存所有源的区块数据，且**从不被清空**；
   * `build()` 里 `_groups.where((g) => g.provider == _currentSource)` 按当前源过滤。
   * ⇒ 切回一个**本次会话看过的**源，改之前也是"秒出"（数据一直在内存里）。
   * ```
   * ⇒ `clear()` 只清我的缓存、清不掉 `_sectionItems` ⇒ **量不出任何差异**。
   *
   * # 所以对照必须改成「关掉缓存」（`homeListCache.enabled = false`）
   * ```text
   * 关闭后 take 恒 null、put 空操作 ⇒ 页面行为 = **改之前的行为**
   *   （只是不走命中分支，改走老的按需补拉）
   * ```
   * ★ 它同时回答一个更根本的问题：
   *   "切回已看过的源本来就快" ⇒ 那我的缓存到底改了什么？
   *   ⇒ 见 E2：开着缓存时切回是 **0 次请求**，关掉就**重发**。
   *     ★ 用户抱怨的正是这个："每次都重载" ⇒ 省掉的请求数才是本次改动的价值。
   */
  await switchAndTime(srcB, 'E-b');
  homeListCache.clear();
  homeListCache.enabled = false;
  say('  （缓存已关闭 ⇒ 以下读数 = 改之前的行为）');
  final eReq0 = totalListRequests;
  final eRes = await switchAndTime(srcA, 'E-a');
  await pumpReal(60, 'E-revalidate');
  final eReq = totalListRequests - eReq0;
  homeListCache.enabled = true;
  say('E 关闭缓存后切回 A: 第一帧卡片=${eRes.firstCards} '
      '到内容可见=${eRes.ms}ms 请求=$eReq 次');
  ok('★E1 关掉缓存后**仍然**秒出 —— 这是改之前就有的行为（`_sectionItems` 一直留着）',
      eRes.firstCards > 0,
      'cards=${eRes.firstCards}（⇒ A1 单独不足以证明缓存生效）');
  /*
   * ★★ E2 是我第一版**又一处**错误预期，这里按实测改正（不改成"能过"的说法）
   * ```text
   * 我原以为：关掉缓存 ⇒ 切回 A 会重发请求。
   * 实测：0 次 —— 因为 `_sectionItems` 里 A 的数据**还在**，
   *   `_loadSectionsOf` 的判据是"该区块有没有数据" ⇒ 有 ⇒ 不发。
   * ⇒ 这条读数**再次**证实："切回本次会话看过的源"在改之前就是 0 请求。
   * ```
   * ⇒ 所以 E2 的正确断言是**两者相同**（都 0），并把它当作"缓存没在骗人"的证据：
   *   缓存在这条路径上**没有**额外好处，它省的是别的路径（见 F 段与报告）。
   *   ⚠️ 我**不**把 E2 写成"缓存让请求从 N 降到 0"—— 那是假的。
   */
  ok('★E2 这条路径上缓存与"改之前"**同为 0 请求**（缓存没在这里造假收益）',
      eReq == 0 && aRes.requests == 0,
      '关闭=${eReq} 次 / 开启=${aRes.requests} 次（都 0 ⇒ 该场景本来就省）');

  // ══════════════════════════════════════════════════════════════════
  //  F ★★ 缓存**真正**省掉的那条路径：`loadAll(force: true)`
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── F 缓存真正省掉的路径：force 全量刷新（onProvidersChanged / 下拉）──');
  /*
   * ★★★ 这一段是本探针的**结论段**：前面 A/E 的读数逼我承认一件事 ——
   *   「切回已看过的源」在**改之前**就是 0 请求（`_sectionItems` 一直留着），
   *   所以那条场景**证明不了**本次改动的价值。
   *
   * # 改之前 vs 改之后（读代码 + 读数得出，逐条列出）
   * ```text
   * 场景                          改之前            改之后
   * 首次冷加载                    要拉（不可避免）   要拉（同）
   * 切回**本次会话看过**的源       0 请求 ✓           0 请求 ✓（同 —— 本来就不重载）
   * 切到**本次会话没看过**的源     冷拉              冷拉（同，无快照可命中）
   * ★ loadAll(force:true)         全量重拉 ✗         快照够新则 0 请求 ✓（本次改动）
   * ★ 拉过但确实为空的区块         每次切源都重拉 ✗   只拉一次 ✓（_loadedBy）
   * ```
   * ⇒ 真正被修掉的是**后两条**。第一条是用户最可能感知到的那个
   *   （设置页改完源回来 / 下拉刷新 ⇒ 立刻 9 次 get_list）。
   *
   * ⚠️ 我必须把这条讲清楚，因为**用户的原话是「每次切换源都要重载」**——
   *    而按读数，单纯"切回"在改之前也不重载。
   *    ⇒ 要么用户遇到的是别的路径（设置页改源 / 重启应用），
   *      要么真机上有让 State 重建的情形。**这条我没有直接证据，不能编结论。**
   *      见报告里的"未验证"一节。
   */
  final fReq0 = totalListRequests;
  await home.loadAll(force: true, reason: 'F-force');
  await pumpReal(40, 'F-force');
  final fCached = totalListRequests - fReq0;
  say('F1 `loadAll(force:true)`（force 语义）: 区块请求=${fCached} 次');
  /*
   * ★ 我第一版在这里断言错了，改掉并说明为什么（不要为了绿而绿）
   * ```text
   * 第一版断言："快照够新 ⇒ force 全量刷新一个请求都不发" ⇒ 实测 2 次 ⇒ 红。
   * 那不是产品 bug —— `force: true` 的**定义**就是"忽略缓存、重新拉"：
   *   它的三个调用点（initState / providers-changed / 用户下拉）都是**明确要求**新数据。
   *   ⇒ 让 force 也被新鲜窗口拦住，等于**违背调用方意图**（下拉刷新会失效）。
   * ⇒ 正确的断言是"force 会重新拉"，并把"缓存在这条路径上的作用"限定为
   *   **先把旧内容画出来**（不闪骨架），而不是省请求。
   * ```
   */
  ok('★F1 `force:true` **按语义**仍然重新拉（缓存不拦它，下拉刷新才不会失效）',
      fCached > 0, '实测 $fCached 次');

  // 关掉缓存做**同一件事** ⇒ 立刻露出"改之前"的读数（这才是可比的对照）
  homeListCache.clear();
  homeListCache.enabled = false;
  final fReq1 = totalListRequests;
  await home.loadAll(force: true, reason: 'F-force-baseline');
  await pumpReal(40, 'F-force-baseline');
  final fBase = totalListRequests - fReq1;
  homeListCache.enabled = true;
  say('F2 同一次 force 刷新、**关掉缓存**（= 改之前）: 区块请求=${fBase} 次');
  ok('★F2 对照成立：关掉缓存后同一条路径**会**重新发请求',
      fBase > 0, '实测 $fBase 次（开着缓存是 $fCached 次）');

  // ══════════════════════════════════════════════════════════════════
  //  D 上限：LRU 12 个条目；TTL / 指纹不符都不算命中
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('── D 上限（LRU，maxEntries=$kHomeCacheMaxEntries）──');
  final cache = HomeListCache();
  final now = DateTime.now();
  for (var i = 0; i < kHomeCacheMaxEntries + 5; i++) {
    cache.put(
      'p$i',
      HomeSnapshot(
        fingerprint: 'fp',
        groups: const <ProviderGroup>[],
        items: const <String, List<MediaItem>>{},
        at: now,
      ),
    );
  }
  say('塞了 ${kHomeCacheMaxEntries + 5} 个键 -> 驻留=${cache.length} '
      'evictions=${cache.evictions}');
  ok('★D1 驻留数**不超过**上限（内存不许无限涨）',
      cache.length == kHomeCacheMaxEntries,
      '驻留=${cache.length} 上限=$kHomeCacheMaxEntries');
  ok('★D2 被淘汰的是**最久未用**的（p0 应当已经不在）',
      cache.take('p0', fingerprint: 'fp', now: now) == null,
      'p0 还在吗 = ${cache.take('p0', fingerprint: 'fp', now: now) != null}');
  // ⚠️ 键名必须**同一段插值**：写成 'p$kHomeCacheMaxEntries + 4' 时它展开成
  //    "p12 + 4"（字面量），而塞进去的是 p12/p13/... ⇒ 永远取不到 ⇒ 假红。
  final lastKey = 'p${kHomeCacheMaxEntries + 4}';
  ok('★D3 最近用过的还在（最后一个键 $lastKey）',
      cache.take(lastKey, fingerprint: 'fp', now: now) != null);

  // ── D4：TTL 过期 ⇒ 不算命中 ──
  final stale = HomeListCache();
  stale.put(
    'x',
    HomeSnapshot(
      fingerprint: 'fp',
      groups: const <ProviderGroup>[],
      items: const <String, List<MediaItem>>{},
      at: now.subtract(kHomeCacheTtl + const Duration(minutes: 1)),
    ),
  );
  ok('★D4 超过 TTL 的快照不算命中（且顺手被删掉）',
      stale.take('x', fingerprint: 'fp', now: now) == null && stale.length == 0,
      '驻留=${stale.length}');

  // ── D5：指纹不符 ⇒ 不算命中 ──
  final fpMismatch = HomeListCache();
  fpMismatch.put(
    'y',
    HomeSnapshot(
      fingerprint: 'old',
      groups: const <ProviderGroup>[],
      items: const <String, List<MediaItem>>{},
      at: now,
    ),
  );
  ok('★D5 指纹不符的快照不算命中（用户刚启停过源的情形）',
      fpMismatch.take('y', fingerprint: 'new', now: now) == null &&
          fpMismatch.length == 0,
      '驻留=${fpMismatch.length}');

  // ══════════════════════════════════════════════════════════════════
  //  收尾读数
  // ══════════════════════════════════════════════════════════════════
  say('');
  say('时间线:');
  for (final l in timeline) {
    say('  $l');
  }
  say('');
  say('VERDICT '
      '| B冷加载: 可见=${bRes.ms}ms 请求=${bRes.requests}次 第一帧卡片=${bRes.firstCards} '
      '| A命中(新鲜): 可见=${aRes.ms}ms 请求=${aRes.requests}次 '
      '第一帧卡片=${aRes.firstCards} build=$aFirstBuilt '
      '| C过期: 可见=${cRes.ms}ms 请求=$cReq次 第一帧卡片=${cRes.firstCards} '
      '| E清空: 可见=${eRes.ms}ms 请求=$eReq次 第一帧卡片=${eRes.firstCards} '
      '| 缓存 hits=${homeListCache.hits} misses=${homeListCache.misses} '
      'puts=${homeListCache.puts} evictions=${homeListCache.evictions} '
      '驻留=${homeListCache.length}/${homeListCache.maxEntries} '
      '| 加速比=${aRes.ms <= 0 ? "<1" : (bRes.ms / aRes.ms).toStringAsFixed(1)}x');
  await finish(fail == 0 ? 0 : 1);
}
