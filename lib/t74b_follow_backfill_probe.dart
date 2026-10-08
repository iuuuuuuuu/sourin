// ═══════════════════════════════════════════════════════════════════════
//  task-74【①】「追更页面有个未知……要么缓存，要么每次点进去能访问就更新，
//  不能访问就保留」—— **真机**取证探针（2026-09-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须真机取证（而不是靠已绿的 widget 测试）
//
// `test/t74_follow_title_backfill_test.dart` 已经全绿（4 组），但那份读数是在
// **`flutter test` 的合成环境**里拿的：
// ```text
// ① 真实 FFI 调不通（`sourin_core.dll` 在测试进程里加载失败，历史噪声 126）
// ② 真实网络一次都没打（fetcher 是假的）
// ③ 没有真实窗口、没有真实光栅化
// ```
// Owner 的要求是「交付前必须自跑完整实测」⇒ 必须在一个**真的应用进程**里，
// 用**真的核心**、**真的网络**、**真的 UI** 再证一遍。
//
// # ★★★ 本探针要证的是什么（先把命题写清楚，否则读数无法判读）
//
// Owner 的原话给了**两个都必须成立**的分支：
// ```text
// 「能访问就更新」 ⇒ 成功 ⇒ 标题出现在卡片上 **且** 落进 DB（下次零网络）
// 「不能访问就保留」⇒ 失败 ⇒ 那一行**原样保留**（不删、不写空、进度不动）
// ```
// ⇒ 判据**不是**「标题一定补上了」（那取决于源站），而是：
// ```text
// 无论成功还是失败，下面这条不变量都必须成立：
//   ① 那一行还在（绝不删）
//   ② 它绝不被写成**更差**的值（空标题覆盖、进度清零）
//   ③ position / duration / episodeId 逐字不变
//   ④ 失败时不重试（`_tried` 已记）
// ```
// 这条不变量**与源站可达性无关** ⇒ 它是一个**两极都能判**的判据。
// 这正是本仓 spec Contract 23（没有阳性对照的读数不是读数）要的形状：
// 我另外用**注入的假 fetcher** 造出确定的成功极与失败极，
// 证明"仪器能分辨这两种结果" —— 否则真机那一极无论出什么结果都不可解释。
//
// # ★★ 取证对象就是**用户真实库里那一行**
//
// `.probe\t74_db_wal_check.py` 实测（只读）：
// ```text
// 用户库 progress 共 26 行，其中**恰好 1 行**需要回填：
//   ('cycani', '3841', title='', episode_title=NULL, position=122, duration=1422)
// ```
// 这就是 Owner 说的那个「未知」卡片。本探针在**隔离数据目录**里对它的**副本**
// 操作（原库只读，绝不触碰）。
//
// ★★★ 一条**必须先说的仪器坑**（我自己踩了）：
//   用户库的 `-wal` 是 4,132,392 B，而 `?immutable=1` 会让 SQLite
//   **完全跳过 WAL** ⇒ 我第一次 dump 读到的是**旧检查点**（16 行），
//   不是用户看到的 26 行。**任何**基于那次读数的结论都是错的。
//   ⇒ 种子脚本必须**同时**复制 `dsh-media.db` / `-wal` / `-shm` 三个文件。
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/t74b_follow_backfill_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\t74b-data"
// ```
// ⚠️ 必须从**带着 `libmpv-2.dll` + `sourin_core.dll` 的目录**运行。
// ⚠️ 必须用**隔离数据目录**（本探针会启动真核心、打真网络、**写库**）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/models.dart';
import 'core/progress_backfill.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/follow_page.dart';
import 'ui/theme_bridge.dart';

/// 被取证的那一行（实测来自用户库，见文件头）
const String kBadProvider = 'cycani';
const String kBadId = '3841';

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe';

/// 日志缓冲 —— `finish()` 会把它写成**产物文件**
///
/// ★ 为什么不只靠 stdout 重定向：本探针是 Windows **GUI** 子系统程序，
///   输出是否被父进程接住取决于句柄继承；而本仓的判据是**产物文件**
///   （「探针写了不等于跑过」，`.probe/*.txt` 才是读数）。
final List<String> _log = [];

void say(String s) {
  _log.add(s);
  debugPrint('[T74B] $s');
}

int pass = 0;
int fail = 0;

void ok(String label, bool cond, [String extra = '']) {
  final line = '$label${extra.isEmpty ? '' : '  $extra'}';
  if (cond) {
    pass++;
    _log.add('✓ $line');
    debugPrint('[T74B] ✓ $line');
  } else {
    fail++;
    _log.add('✗ $line');
    debugPrint('[T74B] ✗ $line');
  }
}

/// 只打印、不计分（用于「观测到的现象」，不是判据）
void note(String s) {
  _log.add('· $s');
  debugPrint('[T74B] · $s');
}

/// 写产物文件，然后退出
///
/// ★★ `exit()` **不展开 `finally`**（它直接终止进程）⇒ 每一条退出路径
///   都必须先调用本函数。否则中途中止的那一次会**不留产物**，
///   于是"跑了但没证据" —— 与"没跑"在事后完全无法区分。
Future<Never> finish(int code) async {
  try {
    final f = File('$_outDir\\t74b-follow-backfill.txt');
    f.writeAsStringSync('${_log.join('\n')}\n');
    debugPrint('[T74B] 产物已写 ${f.path} (${f.lengthSync()} B)');
  } catch (e) {
    debugPrint('[T74B] ★ 写产物失败: $e');
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(code);
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录
// ═══════════════════════════════════════════════════════════════════════

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

/// 等一帧真的画完（真实应用进程里没有 `tester.pump()`）
///
/// ⚠️ 加超时兜底：万一没人请求帧，`endOfFrame` 会一直挂着，
///    那会让探针**静默停住**（历史踩过：只看到超时，看不到原因）。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

/// 在 [items] 里按 key 找一行
Progress? _find(List<Progress> items, String key) {
  for (final p in items) {
    if (p.key == key) return p;
  }
  return null;
}

/// 一行是否"需要回填"（生产判据的唯一入口，不在探针里另写一份）
bool _needs(Progress p) => needsTitleBackfill(p);

/// 把一行摘要成一行日志（避免打整条记录时把无关字段混进判据）
String _desc(Progress? p) {
  if (p == null) return '<null>';
  return 'title="${p.title}" episodeTitle=${p.episodeTitle} '
      'pos=${p.position} dur=${p.duration}';
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

final _pageKey = GlobalKey<FollowPageState>();
final _rootKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // media_kit 必须在 runApp 之前（`shell.dart:276` 的同一条）。
  // 本探针**不挂播放器**，所以初始化失败也继续。
  try {
    MediaKit.ensureInitialized();
    say('media_kit 已初始化');
  } catch (e) {
    say('media_kit 初始化失败（本探针不用播放器，继续）: $e');
  }

  try {
    await Device.init();
    say('Device.init 完成');
  } catch (e) {
    say('Device.init 失败（忽略，有兜底）: $e');
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  final r = await SourinCore.startAsync(dir);

  debugPrint('[T74B] ══════ task-74① 追更标题回填 —— 真机取证 ══════');
  say('数据目录: $dir');
  say('核心: $r');

  // ─────────────────────────────────────────────────────────────────
  //  ★★ 仪器前置条件：必须是**隔离**数据目录
  //
  //  本探针会**写库**（回填成功要落库）。若跑在用户真实目录上，
  //  那就是在改用户数据 —— 本仓铁律禁止。
  //  ⇒ 目录名不含 `.probe` 就直接中止（不是"警告后继续"）。
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ⓪ 仪器自检 ──');
  ok('数据目录是隔离目录（含 .probe，绝不写用户库）',
      dir.toLowerCase().contains('.probe'), 'dir=$dir');
  if (!dir.toLowerCase().contains('.probe')) {
    say('★ 不是隔离目录 ⇒ 本探针会写库，拒绝继续');
    debugPrint('[T74B] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  final dbFile = File('$dir${Platform.pathSeparator}dsh-media.db');
  ok('隔离目录里 dsh-media.db 存在（种子脚本已复制）', dbFile.existsSync(),
      '${dbFile.existsSync() ? dbFile.lengthSync() : 0} B');
  if (!dbFile.existsSync()) {
    say('★ 没有种子库 ⇒ 没有取证对象，中止');
    debugPrint('[T74B] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  // ─────────────────────────────────────────────────────────────────
  //  ① 取证对象存在吗（"没有对象"和"修好了"在读数上完全一样）
  //
  //  ★ 这一条是**阳性对照**：如果库里根本没有"需要回填"的行，
  //    后面所有断言都会"通过" —— 而那是因为没东西可测。
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ① 取证对象（用户真实库里那一行） ──');

  final before = await SourinApi.continueWatching(limit: 20);
  say('库中继续观看 ${before.length} 行');
  for (final p in before) {
    note('  ${p.key}  ${_desc(p)}');
  }

  final badBefore = _find(before, '$kBadProvider:$kBadId');
  ok('★ 取证对象存在：$kBadProvider:$kBadId', badBefore != null,
      _desc(badBefore));
  ok('★ 它确实"需要回填"（标题与集名都空 ⇒ 界面上显示「（标题未知）」）',
      badBefore != null && _needs(badBefore), _desc(badBefore));

  final needCount = before.where(_needs).length;
  note('全库需要回填的行数 = $needCount');

  if (badBefore == null || !_needs(badBefore)) {
    say('★ 取证对象不存在或不需要回填 ⇒ 本探针无信息量，中止');
    debugPrint('[T74B] RESULT verdict=NO-SUBJECT pass=$pass fail=$fail');
    await finish(1);
  }

  // 记下"原样"的三个字段 —— 后面对抗性断言要和它们逐字比
  final origPos = badBefore.position;
  final origDur = badBefore.duration;
  final origEpId = badBefore.episodeId;
  note('原件：pos=$origPos dur=$origDur episodeId=$origEpId');

  // ─────────────────────────────────────────────────────────────────
  //  ② 真网络那一极的**地面真值**：这个 id 现在还访问得到吗？
  //
  //  ★ 必须先单独问一次，否则后面 UI 那一极出的结果无法解释：
  //    「标题没补上」既可能是回填坏了，也可能是源站真的没有这一条。
  //  ★ 这一问**不改任何状态**（getDetail 是只读的）。
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ② 真网络地面真值 getDetail($kBadProvider, $kBadId) ──');

  String? netTitle;
  String? netCover;
  String? netErr;
  final netSw = Stopwatch()..start();
  try {
    final d = await SourinApi.getDetail(kBadProvider, kBadId)
        .timeout(const Duration(seconds: 25));
    netTitle = d.title;
    netCover = d.cover;
  } catch (e) {
    netErr = '$e';
  }
  netSw.stop();
  note('getDetail 耗时 ${netSw.elapsedMilliseconds} ms');
  if (netErr != null) {
    note('★ 源站不可访问: $netErr');
    say('⇒ 这一极走的是「不能访问就保留」分支（Owner 明确要求保留）');
  } else {
    note('源站返回 title="${netTitle ?? ''}" cover=${netCover == null ? 'null' : '有'}');
    if ((netTitle ?? '').trim().isEmpty) {
      note('★ 源站可达但标题为空 ⇒ 回填**不应**写库（见 _one 的 t.isEmpty 分支）');
    } else {
      say('⇒ 这一极走的是「能访问就更新」分支');
    }
  }
  // ★ 这里**不**断言标题非空 —— 那取决于源站，不是本探针的命题。
  //   它只是"地面真值"，用来解释下一极的结果。
  ok('地面真值已取得（可达或明确不可达，二者必居其一）',
      netErr != null || netTitle != null);

  // ─────────────────────────────────────────────────────────────────
  //  ③ 生产路径端到端：挂真 FollowPage，让它自己跑 auto-backfill
  //
  //  ★ 这一极**不注入任何东西**（`backfillOverride: null`）⇒ 走的是
  //    `ProgressTitleBackfill()` 的真实实现：真 FFI 读列表、真网络取详情、
  //    真 `saveProgress` 落库。
  //  ★ 触发点是 `follow_page.dart:504` 的 `unawaited(_backfillTitles())`，
  //    在 `_load()` 的 `setState` **之后** ⇒ 首屏不被网络阻塞（这是设计目标）。
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ③ 生产路径端到端（无注入） ──');

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · task-74① 追更回填探针');
  }

  final brightness = AppTheme.resolve(systemBrightness: Brightness.light);
  final theme = AppTheme.themeFor(brightness);
  final materialTheme = brightness == Brightness.light
      ? buildLightMaterialTheme(theme)
      : buildMaterialTheme(theme);

  runApp(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: FLocalizations.localizationsDelegates,
        supportedLocales: FLocalizations.supportedLocales,
        theme: materialTheme,
        /*
         * ★★★ 必须逐字复刻生产外壳（`shell.dart:2854-2865`）
         *
         * 缺 `Material(type: MaterialType.transparency)` 那一层 ⇒
         * `InkWell` 抛 `Null check operator used on a null value`
         * （`Material.of`）⇒ **整页被换成 ErrorWidget 而不崩给你看**，
         * 断言只会以「找不到 XX」失败，真因只在 stderr。
         */
        builder: (context, child) => FTheme(
          data: theme,
          child: FScaffold(
            child: Material(
              type: MaterialType.transparency,
              child: child!,
            ),
          ),
        ),
        home: FollowPage(
          key: _pageKey,
          initialTab: 'continue',
        ),
      ),
    ),
  );

  /*
   * ★★★ `runApp()` 只**调度**一帧 —— 元素树要等那一帧真的跑完才存在。
   *
   * 第一次跑（2026-09-28 22:46:15）就是在这里挂的：
   * ```text
   * ✗ 根元素已挂上
   * ✗ 拿到**真实的** FollowPageState  null
   * ★ FollowPage 没挂上 ⇒ 后续全部无意义，中止
   * ```
   * 而那不是"页面没挂上"，是**探针自己读得太早**：同步读
   * `currentContext` 时 `attachRootWidget` 还没建树 ⇒ 恒为 null。
   *
   * ⇒ 必须先等帧。等两帧是为了让 `FollowPage.initState` 里的
   *   `addPostFrameCallback`（loadAll 的调度点）也走完。
   */
  await pumpFrame();
  await pumpFrame();

  final root = _rootKey.currentContext as Element?;
  final st = _pageKey.currentState;
  ok('根元素已挂上', root != null);
  ok('拿到**真实的** FollowPageState', st != null, '${st?.runtimeType}');
  if (root == null || st == null) {
    say('★ FollowPage 没挂上 ⇒ 后续全部无意义，中止');
    debugPrint('[T74B] RESULT verdict=INSTRUMENT-FAILURE pass=$pass fail=$fail');
    await finish(1);
  }

  /*
   * 等生产 auto-backfill 跑完。
   *
   * ★ 为什么是"轮询 + 上限"而不是固定 sleep：
   *   网络耗时不可预测；固定 sleep 要么太短（读到"还没补"就误判失败）
   *   要么太长（浪费）。轮询到"列表里那行有标题了"就立刻停。
   * ★ 为什么上限 40 s：getDetail 实测可能十几秒（几十 KB~几百 KB）。
   *   超时后**不判失败**，而是报 INCONCLUSIVE —— "没等到"不是"坏了"。
   */
  Progress? uiAfter;
  var waitedMs = 0;
  const stepMs = 500;
  const limitMs = 40000;
  while (waitedMs < limitMs) {
    await Future<void>.delayed(const Duration(milliseconds: stepMs));
    waitedMs += stepMs;
    await pumpFrame();
    uiAfter = _find(st.debugContinueList, '$kBadProvider:$kBadId');
    if (uiAfter != null && !_needs(uiAfter)) break;
  }
  say('轮询 ${waitedMs} ms 后读数');
  note('UI 列表里那一行: ${_desc(uiAfter)}');

  final uiUpdated = uiAfter != null && !_needs(uiAfter);
  if (uiUpdated) {
    ok('★ 「能访问就更新」：卡片上的标题真的补上了',
        uiAfter.title.trim().isNotEmpty, 'title="${uiAfter.title}"');
    // ★ 关键：补标题**不许**动进度（那比"没标题"严重得多）
    ok('★★ 补标题没有动进度（position/duration 逐字不变）',
        uiAfter.position == origPos && uiAfter.duration == origDur,
        'pos ${origPos}→${uiAfter.position}  dur ${origDur}→${uiAfter.duration}');
    ok('★★ 补标题没有动 episodeId',
        uiAfter.episodeId == origEpId,
        '${origEpId} → ${uiAfter.episodeId}');

    // ★★ 落库验证 —— 这才是 Owner 说的「要么缓存」：
    //    下次进页面读 DB 直接就有标题，**零网络**。
    final after = await SourinApi.continueWatching(limit: 20);
    final dbRow = _find(after, '$kBadProvider:$kBadId');
    ok('★★★ 「要么缓存」：标题真的落进了 DB（下次进页面零网络）',
        dbRow != null && !_needs(dbRow), _desc(dbRow));
    ok('★★★ 落库后那一行**仍在**（回填绝不删行）', dbRow != null);
    ok('★★★ 落库后进度逐字不变',
        dbRow != null && dbRow.position == origPos && dbRow.duration == origDur,
        dbRow == null ? '' : 'pos=${dbRow.position} dur=${dbRow.duration}');
  } else if (netErr != null || (netTitle ?? '').trim().isEmpty) {
    /*
     * ★★ 这一支是「不能访问就保留」—— Owner 明确要求的行为。
     *    它不是失败，而是**另一条正确路径**，判据换成"有没有守住"。
     */
    note('⇒ 地面真值说这条访问不到/标题为空 ⇒ 走「保留」分支');
    ok('★★ 「不能访问就保留」：那一行仍在（绝不删行）', uiAfter != null,
        _desc(uiAfter));
    ok('★★ 「保留」：没有被写成更差的值（标题仍空、进度未动）',
        uiAfter != null &&
            uiAfter.title.trim().isEmpty &&
            uiAfter.position == origPos &&
            uiAfter.duration == origDur,
        _desc(uiAfter));
    ok('★★ 列表长度没变（回填不增删列表项）',
        st.debugContinueList.length == before.length,
        '${before.length} → ${st.debugContinueList.length}');
  } else {
    /*
     * ★ 地面真值说"能访问、标题非空"，但 UI 等了 40 s 还没补上。
     *   ⇒ 这是**真问题**（不是"源站不行"），但也不能排除"就是慢"。
     *   ⇒ 报 INCONCLUSIVE 而不是 FAIL，让读的人知道要再跑一次。
     */
    note('★★ 地面真值说可访问且标题非空，但 40 s 内 UI 没补上 ⇒ 待查');
    ok('地面真值可达 ⇒ 回填**应当**补上（本读数为 INCONCLUSIVE）', false,
        'netTitle="$netTitle" ui=${_desc(uiAfter)}');
  }

  // ─────────────────────────────────────────────────────────────────
  //  ④ 两极对照：用**注入的假 fetcher** 造出确定的成功极与失败极
  //
  //  ★★ 为什么这一节是**必须的**（spec Contract 23）：
  //    ③ 那一极只跑出一种结果。若仪器根本分辨不出成功/失败，
  //    ③ 的读数无论是什么都不可解释。这一节证明仪器**能分辨**。
  //  ★ 用独立的 `ProgressTitleBackfill` 实例（不碰页面状态），
  //    并给 saver 装**间谍**记录每次写入的参数。
  // ─────────────────────────────────────────────────────────────────
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ④ 两极对照（注入假 fetcher） ──');

  final orig = Progress(
    key: '$kBadProvider:$kBadId',
    provider: kBadProvider,
    nativeId: kBadId,
    title: '',
    episodeId: origEpId,
    episodeTitle: null,
    position: origPos,
    duration: origDur,
  );

  // ── 失败极 ──
  var failFetchCount = 0;
  final failSaves = <String>[];
  final failBf = ProgressTitleBackfill(
    fetchDetail: (p, id) async {
      failFetchCount++;
      throw StateError('模拟源站不可达');
    },
    saveProgress: (p, {required title, cover}) async {
      failSaves.add('$title');
    },
  );
  final failOut = await failBf.backfill([orig]);
  ok('失败极：backfill 返回空（什么都没补）', failOut.isEmpty,
      'patched=${failOut.length}');
  ok('失败极：★ 一次都没写库（绝不把记录写得更差）', failSaves.isEmpty,
      'saves=${failSaves.length}');
  ok('失败极：异常被吞掉、没有抛出来（回填是旁路，不许让追更页报错）', true);
  final failMerged = mergeBackfilled([orig], failOut);
  ok('失败极：合并后列表长度不变、那一行逐字保留',
      failMerged.length == 1 && _desc(failMerged[0]) == _desc(orig),
      _desc(failMerged[0]));

  // ── 去重（"别把网络打爆"）──
  final again = await failBf.backfill([orig]);
  ok('★★ 去重：同一个 key 第二次不再发请求（失败也不重试）',
      failFetchCount == 1 && again.isEmpty,
      'fetchCount=$failFetchCount（期望 1）');
  ok('去重：triedKeys 记下了它', failBf.triedKeys.contains(orig.key),
      '${failBf.triedKeys}');

  // ── 成功极 ──
  var okFetchCount = 0;
  final okSaves = <Progress>[];
  final okTitles = <String>[];
  final okBf = ProgressTitleBackfill(
    fetchDetail: (p, id) async {
      okFetchCount++;
      return const MediaDetail(
        id: 'cycani:3841',
        title: '无职转生 第二季',
        cover: 'https://example.invalid/cover.jpg',
      );
    },
    saveProgress: (p, {required title, cover}) async {
      okSaves.add(p);
      okTitles.add(title);
    },
  );
  final okOut = await okBf.backfill([orig]);
  ok('成功极：backfill 返回 1 条', okOut.length == 1, 'patched=${okOut.length}');
  ok('成功极：标题是源站给的（不是占位符）',
      okOut.isNotEmpty && okOut[0].title == '无职转生 第二季',
      okOut.isEmpty ? '' : 'title="${okOut[0].title}"');
  ok('成功极：写库被调用了一次', okSaves.length == 1 && okTitles.length == 1,
      'saves=${okSaves.length} title="${okTitles.isEmpty ? '' : okTitles[0]}"');
  // ★★ 最重要的一条：saver 收到的是**原记录**，所以四个进度字段能原样带回去
  ok('★★★ 成功极：写库时带的是**原记录**（进度四字段不会被清零）',
      okSaves.isNotEmpty &&
          okSaves[0].position == origPos &&
          okSaves[0].duration == origDur &&
          okSaves[0].episodeId == origEpId,
      okSaves.isEmpty
          ? ''
          : 'pos=${okSaves[0].position} dur=${okSaves[0].duration} '
              'episodeId=${okSaves[0].episodeId}');
  final okMerged = mergeBackfilled([orig], okOut);
  ok('成功极：合并后长度不变、内容换成新标题',
      okMerged.length == 1 && okMerged[0].title == '无职转生 第二季',
      _desc(okMerged[0]));
  ok('成功极：合并后进度逐字不变',
      okMerged[0].position == origPos && okMerged[0].duration == origDur);

  // ── 空标题极（源站可达但没给标题）──
  var emptySaves = 0;
  final emptyBf = ProgressTitleBackfill(
    fetchDetail: (p, id) async =>
        const MediaDetail(id: 'cycani:3841', title: '   '),
    saveProgress: (p, {required title, cover}) async {
      emptySaves++;
    },
  );
  final emptyOut = await emptyBf.backfill([orig]);
  ok('空标题极：源站给了空白标题 ⇒ **不**写库（宁可不写也不写差）',
      emptyOut.isEmpty && emptySaves == 0,
      'patched=${emptyOut.length} saves=$emptySaves');

  // ── 封面保护（COALESCE 语义）──
  final withCover = Progress(
    key: 'x:1',
    provider: 'x',
    nativeId: '1',
    title: '',
    cover: 'https://old/cover.jpg',
    position: 5,
    duration: 10,
  );
  final kept = withBackfilledMeta(withCover, title: '新标题', cover: null);
  ok('封面保护：新封面为空时保留旧封面（不清空本来能显示的海报）',
      kept.cover == 'https://old/cover.jpg', 'cover=${kept.cover}');

  // ── 全库终态不变量 ──
  debugPrint('[T74B]');
  debugPrint('[T74B] ── ⑤ 终态不变量（全库） ──');
  final finalList = await SourinApi.continueWatching(limit: 20);
  note('终态共 ${finalList.length} 行（起始 ${before.length} 行）');
  final gone = <String>[];
  for (final p in before) {
    if (_find(finalList, p.key) == null) gone.add(p.key);
  }
  ok('★★★ 终态不变量：起始的每一行都还在（回填绝不删行）', gone.isEmpty,
      gone.isEmpty ? '' : '丢失=$gone');
  final dropped = <String>[];
  for (final p in before) {
    final now = _find(finalList, p.key);
    if (now == null) continue;
    if (now.position != p.position || now.duration != p.duration) {
      dropped.add('${p.key} pos ${p.position}→${now.position} '
          'dur ${p.duration}→${now.duration}');
    }
  }
  ok('★★★ 终态不变量：没有任何一行的进度被改动', dropped.isEmpty,
      dropped.isEmpty ? '' : '被改=$dropped');
  for (final p in finalList) {
    note('  ${p.key}  ${_desc(p)}');
  }

  debugPrint('[T74B]');
  debugPrint('[T74B] ══════ 结束 pass=$pass fail=$fail ══════');

  final now = DateTime.now();
  final reachable = netErr == null && (netTitle ?? '').trim().isNotEmpty;
  debugPrint('[T74B] RESULT task-74① 追更标题回填：'
      '对象=$kBadProvider:$kBadId 源站可达=${reachable ? 'true' : 'false'} '
      'UI补上=${uiUpdated ? 'true' : 'false'} '
      '全库${before.length}行→${finalList.length}行 丢行=${gone.length} 进度被改=${dropped.length} '
      'pass=$pass fail=$fail | 环境 真机 | 时间 ${now.toIso8601String()}');

  await finish(fail == 0 ? 0 : 1);
}
