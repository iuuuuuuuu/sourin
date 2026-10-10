// ═══════════════════════════════════════════════════════════════════════
//  OPS-9：本地**已经有可播文件**的那一集，不许再画「换源」
// ═══════════════════════════════════════════════════════════════════════
//
// # 现象（Owner 原话，逐字）
// ```text
// > 这个好像是概率性的,**缓存到本地就不要显示换源按钮了**
// ```
//
// # 根因（一句话）
// `lib/ui/detail_page.dart:1420` 的 `_showLocalActions` 是整条操作行**唯一**的
// 判据（消费点 `lib/ui/detail_page.dart:4023` 的 `if (showActions) ...[`）：
// ```text
// _showLocalActions = !widget.isLocalFile || _online;
// ```
// ⇒ 本地页那几枚按钮**画不画**取决于 `NetworkStatus.probe()` 的回包
//   （唯一调用点 `lib/ui/detail_page.dart:1386`，在 `_initLocal()` 里）
// ⇒ 同一台机器上"有时有换源、有时没有" = Owner 说的「概率性」。
//
// # 这一份测试要钉住的两态（★ 必须**都**真的跑起来，缺一个就是假门禁）
// ```text
// A① 本地页 + 有网 + 播放器已报告这一集  ⇒ 换源**不画**（修前：红 / 修后：绿）
// A② 本地页 + 有网 + 播放器还没报告      ⇒ 换源**不画**（修前：红 / 修后：绿）
//    两组都要 收藏/追更/下载 仍在 —— 证明"只是少了换源"，不是整行被藏了
// B  本地页 + 没网                      ⇒ 换源不画（旧行为：整行不画，本来就绿）
// C  在线页 + 无本地文件                ⇒ 换源**画**（阳性对照：证明 A 的"找不到"不是行没了）
// D  正在下载、已有可播片段             ⇒ 换源不画；done=0 的双胞胎 ⇒ 换源画
// E  本地页认回来源（注入记录）          ⇒ 来源 chip 显示站点名（不是 local/本地）
// ```
//
// # 尺子（为什么是 `find.text('换源')`）
// 整份文件只看**真实渲染树**：那枚按钮的文案就是「换源」
// （`lib/ui/detail_page.dart:4109-4113` 里的 `const Text('换源')`）。
// 全仓与本页有关的既有 `find.text('换源')` 断言只有两处，都不冲突：
// ```text
// test/zz_media_shots_test.dart:324          离线本地页（整行不画）⇒ 仍是 findsNothing
// test/zz_cr_next_dup_more_menu_test.dart:256 播放器底栏「更多」菜单（另一个组件）
// ```
//
// # 为什么必须用注入点（而不是真去要详情）
// `flutter test` 里 FFI **必然失败**（`Failed to load dynamic library
// 'sourin_core.dll'`，error code 126）⇒ 在线路径的 `_init()` 必定落进
// `_ErrorView`，本页正文（含操作行）根本不渲染。
// ⇒ 在线那两组走 `debugSetDetail`（`lib/ui/detail_page.dart:851`），
//   与 `test/t64_panel_fixed_test.dart:135-173` 同一手法：
//   绕过的只有"向核心要详情"这一次 IPC，渲染的仍是生产代码。
//
// # 跑法
// ```text
// flutter test test/zz_cr_localbtn_switch_source_test.dart --reporter expanded --concurrency=1
// ```

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart' show CachedEpisode, CachedWork;
import 'package:sourin_spike/ui/detail_page.dart';

const double _panelW = 433.0;
const double _panelH = 900.0;

/// Windows 的反斜杠这样写，免得被任何一层"吃掉"
final String _bs = String.fromCharCode(92);

/// C:\Users\Videos\sourin —— 本地播放的目录
final String _dir = 'C:${_bs}Users${_bs}Videos${_bs}sourin';

/// 磁盘上的文件名（含扩展名）—— 本地会话的 episodeId 就是它
const String _ep01 = '第01集.mp4';

/// 这一集的**绝对路径**（本页的 id / localFile / LocalEpisodeRef.absolutePath 都是它）
final String _ep01Path = '$_dir$_bs$_ep01';

const String _title = '测试影片';
const String _onlineProvider = 'cycani';
const String _onlineId = '3862';

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 真主题 + 定宽面板（与 test/zz_cr_play_detail_origin_test.dart 逐字同源）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: mui.Scaffold(body: mui.Material(child: child)),
  );
}

/// 让**真**事件循环转一会儿（探针3 实测出来的必要条件）
///
/// ★ 为什么非这么写不可：`SourinCore.callAsync` 的回包是
///   `NativeCallable.listener` 走**真**消息端口投递的，而 `testWidgets`
///   的函数体跑在 `FakeAsync` 里 —— 假时钟下真事件循环不转，回包送不进来
///   ⇒ `providerDisplayName()` 的 future 看起来"永不完成"（探针2 就是这么
///   量的：那是**测量方式**的产物，不是产品的形态）。
///   `tester.runAsync` 把一段代码放回真事件循环执行 ⇒ 回包送达；
///   之后的那次 `pump` 再冲刷 fake zone 的微任务队列，续体才跑得起来。
Future<void> _turnRealLoop(WidgetTester t) async {
  await t.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
}

/// 多泵几帧（`_initLocal` 里那几条 await 都要靠泵推进）
Future<void> _settle(WidgetTester t, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
    _claim(t);
  }
}

/// 四枚按钮的**真实**存在情况 —— 一行打出来，RED / GREEN 可以直接对比
String _row(WidgetTester t) {
  String n(String s) => '${find.text(s).evaluate().length}';
  return '收藏=${n('收藏')} 追更=${n('追更')} 换源=${n('换源')} 下载=${n('下载')}';
}

/// 本地页上的「已下载的集」（一集一个文件）
List<LocalEpisodeRef> _localEps() => <LocalEpisodeRef>[
      LocalEpisodeRef(
        fileName: _ep01,
        episodeTitle: '第01集',
        absolutePath: _ep01Path,
        bytes: 2 * 1024 * 1024,
        watchRatio: 0,
      ),
    ];

/// 挂一个**真**本地页（provider=local、id=绝对路径、localFile=绝对路径）
///
/// `online` 决定注入的联网探测结果 —— 这一格就是 Owner 报的「概率性」的开关。
Future<GlobalKey<State<DetailPage>>> _mountLocal(
  WidgetTester t, {
  required bool online,
  String? currentEpisodeId = _ep01,
  List<LocalEpisodeRef>? localEpisodes,
  LocalOriginRecords Function()? records,
}) async {
  NetworkStatus.debugProbe = () async => online;
  addTearDown(NetworkStatus.debugResetForTest);
  if (records != null) {
    debugSetLocalOriginRecords(records);
    addTearDown(() => debugSetLocalOriginRecords(null));
  }
  await t.binding.setSurfaceSize(const Size(_panelW, _panelH));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final eps = localEpisodes ?? _localEps();
  final key = GlobalKey<State<DetailPage>>();
  await t.pumpWidget(_host(
    DetailPage(
      key: key,
      provider: 'local',
      id: _ep01Path,
      embedded: true,
      localFile: _ep01Path,
      localTitle: _title,
      localEpisodeCount: eps.length,
      localEpisodes: eps,
      currentEpisodeId: currentEpisodeId,
      localMeta: CachedWork(
        dirName: _title,
        path: _dir,
        episodes: const <CachedEpisode>[],
      ),
    ),
  ));
  _claim(t);
  await _settle(t);
  return key;
}

/// 在线页：注入一份**真**详情（绕过那一次必然失败的 FFI）
///
/// ★ 必须**同时**传 `episodes:` —— `_episodes` 是独立的 state 字段
///   （见 `debugSetDetail` 的注释与 `test/t64_panel_fixed_test.dart:157-165`）。
Future<GlobalKey<State<DetailPage>>> _mountOnline(WidgetTester t) async {
  NetworkStatus.debugProbe = () async => true;
  addTearDown(NetworkStatus.debugResetForTest);
  await t.binding.setSurfaceSize(const Size(_panelW, _panelH));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<State<DetailPage>>();
  await t.pumpWidget(_host(
    DetailPage(
      key: key,
      provider: _onlineProvider,
      id: _onlineId,
      embedded: true,
    ),
  ));
  // 先让 `_init()` 那条注定失败的 FFI 走完（它会把 _error 置上）
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  _claim(t);

  final d = const MediaDetail(
    id: _onlineId,
    title: '在线剧',
    episodes: <Episode>[
      Episode(id: 'ep-1', title: '第01集'),
      Episode(id: 'ep-2', title: '第02集'),
    ],
  );
  // ignore: avoid_dynamic_calls
  (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  _claim(t);
  return key;
}

/// 一条**真的**入队任务（状态机、去重、广播都是生产代码）
///
/// ⚠️ 必须先把解析器换成"永不返回"的 future：默认解析器走 FFI，在
///    flutter_tester 里必然抛 ⇒ 任务会被置成 failed ⇒ 测不到 running 那一格。
///    （这正是 `DownloadQueue.debugSetResolver` 存在的理由，见
///      `lib/core/download_queue.dart:836-847` 的说明。）
void _enqueueRunning(String ep, {required int done, required int total}) {
  DownloadQueue.debugSetResolver((_) => Completer<StreamCandidate?>().future);
  addTearDown(() => DownloadQueue.debugSetResolver(null));
  DownloadQueue.enqueue(DownloadTask(
    id: '$_onlineProvider:$_onlineId:$ep',
    title: '在线剧',
    episodeTitle: '第01集',
    provider: _onlineProvider,
    mediaId: _onlineId,
    episodeId: ep,
    sourceCode: 'cdn',
    fileName: '第01集 在线剧',
    done: done,
    total: total,
    state: DownloadState.running,
  ));
}

void main() {
  setUp(() {
    DownloadQueue.debugReset();
    NetworkStatus.debugResetForTest();
  });
  tearDown(() {
    DownloadQueue.debugReset();
    NetworkStatus.debugResetForTest();
  });

  group('OPS-9 本地已有可播文件 ⇒ 不画「换源」', () {
    testWidgets('★A① 本地页 + **有网** + 播放器已报告这一集 ⇒ 换源不画', (t) async {
      await _mountLocal(t, online: true);
      debugPrint('[LOCALBTN] A① online=true currentEpisodeId=$_ep01 ' + _row(t));

      expect(find.text('收藏'), findsOneWidget, reason: '★ 操作行本身必须还在');
      expect(find.text('追更'), findsOneWidget, reason: '★ 操作行本身必须还在');
      expect(find.text('下载'), findsOneWidget, reason: '★ 操作行本身必须还在');
      expect(find.text('换源'), findsNothing,
          reason: '★★★ 缓存到本地就不要显示换源按钮了（Owner 原话）—— '
              '这一集磁盘上就有 $_ep01，换源无处可落');
    });

    testWidgets('★A② 本地页 + 有网 + 播放器**还没报告** ⇒ 换源不画', (t) async {
      await _mountLocal(t, online: true, currentEpisodeId: null);
      debugPrint('[LOCALBTN] A② currentEpisodeId=null ' + _row(t));

      expect(find.text('收藏'), findsOneWidget, reason: '★ 操作行本身必须还在');
      expect(find.text('换源'), findsNothing,
          reason: '★★★ 进的就是本地页（本页在播一个本地文件），'
              '而"播放器还没报告"不等于"没有当前集"');
    });

    testWidgets('★B 本地页 + **没网** ⇒ 整条操作行不画（旧行为，不许退化）', (t) async {
      await _mountLocal(t, online: false);
      debugPrint('[LOCALBTN] B online=false ' + _row(t));

      expect(find.text('换源'), findsNothing, reason: '★ 没网时整行不画（Owner ⑬）');
      expect(find.text('收藏'), findsNothing, reason: '★ 没网时整行不画（Owner ⑬）');
    });

    testWidgets('★C 在线页 + 无本地文件 ⇒ 换源照画（阳性对照）', (t) async {
      await _mountOnline(t);
      debugPrint('[LOCALBTN] C 在线页 ' + _row(t));

      expect(find.text('换源'), findsOneWidget,
          reason: '★★★ 阳性对照：证明 A 组那个 findsNothing 不是"行没了"'
              '（同一个 _Info._rest，只差本地文件这一格）');
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
    });

    testWidgets('★D 正在下载且**已有可播片段** ⇒ 换源不画', (t) async {
      final key = await _mountOnline(t);
      _enqueueRunning('ep-1', done: 3, total: 10);
      // ★ 队列自己不会让本页重建（本页没订阅 tasks）——
      //   用"进度记录到了"这次真 setState 推进一帧，再读判据。
      // ignore: avoid_dynamic_calls
      (key.currentState! as dynamic).debugSetResume(const Progress(
        key: '$_onlineProvider:$_onlineId',
        provider: _onlineProvider,
        nativeId: _onlineId,
        title: '在线剧',
        episodeId: 'ep-1',
        position: 30,
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _claim(t);
      debugPrint('[LOCALBTN] D 下载中 done=3/10 ' + _row(t));

      expect(find.text('换源'), findsNothing,
          reason: '★★★ 这一集正在下载且已经落了 3 片（能边下边播）⇒ '
              '盘上马上就有它，换源没有意义');
    });

    testWidgets('★D′ 双胞胎：done=0（还没落片）⇒ 换源照画', (t) async {
      final key = await _mountOnline(t);
      _enqueueRunning('ep-1', done: 0, total: 0);
      // ignore: avoid_dynamic_calls
      (key.currentState! as dynamic).debugSetResume(const Progress(
        key: '$_onlineProvider:$_onlineId',
        provider: _onlineProvider,
        nativeId: _onlineId,
        title: '在线剧',
        episodeId: 'ep-1',
        position: 30,
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _claim(t);
      debugPrint('[LOCALBTN] D′ 下载中 done=0/0 ' + _row(t));

      expect(find.text('换源'), findsOneWidget,
          reason: '★ 一片都没落下（清单都还没拿到）⇒ 还没有可播的东西，'
              '换源必须照画 —— 这是 D 组的尺子自检');
    });

    testWidgets('★E 本地页认回来源 ⇒ 「来源」chip 显示站点名（不是 local/本地）',
        (t) async {
      await _mountLocal(
        t,
        online: true,
        records: () => (
          progress: <Progress>[
            const Progress(
              key: 'cycani:m1',
              provider: 'cycani',
              nativeId: 'm1',
              title: _title,
              updatedAt: 10,
            ),
          ],
          favorites: const <Favorite>[],
        ),
      );
      /*
       * ★ 站点名那一步要**真事件循环**才回得来（见 [_turnRealLoop] 的说明）
       *
       * ⚠️ 探针 4（test/zz_cr_origin_probe4_test.dart）实测出来的时序：
       * 挂载后（只泵假时钟）      cycani=0 本地=0   ← chip 还不存在
       * 第 1 轮真事件循环之后     cycani=1 本地=0   ← 就是这一轮亮起来的
       *
       * 那一轮的日志逐字：
       *   [PROVIDER-NAME] listProviders 失败，退回 id:
       *       SourinCoreException(unsupported): 核心尚未启动 —— 请先调用 sourin_start({dataDir})
       *   [LOCAL] 采用 cycani:m1 作为来源「cycani」（已存为 null:null）
       *
       * ⇒ 结论：这条路**没有**卡死，只是"回包要真事件循环送进来"
       *   （NativeCallable.listener 走真消息端口，假时钟下不转）。
       */
      await _turnRealLoop(t);
      await _settle(t);
      debugPrint('[LOCALBTN] E 来源 chip=' +
          '${find.text('cycani').evaluate().length} ' +
          _row(t));

      expect(find.text('cycani'), findsOneWidget,
          reason: '★★★ task-17 ②：认回来源 ⇒ 显示**站点名**（Owner：'
              '「点击进去的播放也要显示出来原来源，而不是 local」）');
      expect(find.text('换源'), findsNothing, reason: '★ 认回来源也仍然是本地文件 ⇒ 不画');
    });
  });
}
