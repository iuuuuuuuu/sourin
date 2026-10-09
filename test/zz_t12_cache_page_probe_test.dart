// ═══════════════════════════════════════════════════════════════════════
//  task-12 探针：「已缓存」页新增的 ①②③④ 真读数
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份探针要证明的四件事（lead 点名的读数）
// ```text
// ① 封面：真写旁文件（走**生产**的 writeCacheSidecar）⇒ 扫盘读得到
// ② 下载中区块：**队列非空时界面里有它** + **空队列整块不画** + 失败显示原因
// ③ 整剧删除：真删一次 ⇒ 报「删了几个文件 / 多少 MB」+ 页面真刷新 + 不连坐邻居
// ④ provider/id 规范化：同一文件的 5 种写法必须算出同一个 key
// ```
//
// ⚠️ 硬规则：探针产物一律落 $env:TEMP 沙盒（绝对路径断言 + 收尾自清理），
//    **绝不落仓库根**（这个坑本项目出过一次）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerHoverEvent;
import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/// ★ 探针沙盒根 —— 必须是绝对路径，且落在系统临时目录下
Directory _sandboxRoot() {
  final base = Directory.systemTemp.absolute.path;
  final p = '$base${Platform.pathSeparator}t3_12';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 探针沙盒必须是绝对路径，实际 = $p');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

File _writeBytes(String path, int bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x41));
  return f;
}

/// ★ 落一个**格式与生产一致**的旁文件
///
/// # 为什么探针不直接调那个写函数了（task-12 之后）
/// ```text
/// 原来 cache_page.dart 里有一份 `writeCacheSidecar`，探针直接调它。
/// task-12 去重（lead 裁决）后那份实现**已删除** —— 写入侧现在唯一的一份在
/// `lib/core/download_queue.dart:642-655 _writeSidecarFor`，而它是 **private**
/// （`_` 前缀），探针够不着。
/// ⇒ 探针按**同一个契约**落盘：文件名取生产常量 `DownloadQueue.kSidecarName`
///   （不是抄字面量）、字段名与 `_writeSidecarFor` 逐字一致（provider/id/title/cover）。
///   ★ 这样哪怕将来契约改名，探针也会跟着变 —— 不会又造出第二份契约。
/// ```
///
/// ⚠️ 这只是**辅助证据**。端到端那条（真下载 → 真由生产写侧落盘 → 页面画出封面）
///    见 REPORT 的「主证据」一节。
void _seedSidecar(
  Directory dir, {
  required String provider,
  required String id,
  required String title,
  String? cover,
}) {
  final f = File(
    '${dir.path}${Platform.pathSeparator}${DownloadQueue.kSidecarName}',
  );
  f.writeAsStringSync(
    '{"provider":"$provider","id":"$id","title":"$title",'
    '"cover":${cover == null ? 'null' : '"$cover"'}}',
  );
}

/// 与生产外壳一致的包装（照抄 test/bottom_bar_fit_test.dart:55-65）
Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const mui.SizedBox(),
    ),
    home: mui.Scaffold(body: home),
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

// ══════════════════════════════════════════════════════════════════════
//  ★★★ 真 HTTP 必须把真 HttpClient 装回去（否则「真下载」永远跑不起来）
// ══════════════════════════════════════════════════════════════════════
//
// # 实测踩坑（本次卡了整整一轮）
// ```text
// 现象：端到端那条跑 60 秒一直是 `running done=0/0`，没有报错、没有进度、
//       上游 HttpServer 一个请求都没收到。
// 根因：flutter_test 的绑定默认把**全局** HttpClient 换成 mock
//       （flutter_test/lib/src/_binding_io.dart 的 _MockHttpOverrides）：
//       所有请求一律回 **HTTP 400 且一个字节都不发**。
//       ⇒ HlsDownloader 的 `_getBytes`（hls_download.dart:449）拿到 400，
//         但那条路上没有回退……于是永远停在 running。
// ★ 也就是说：不装真 HttpClient，「真下载」这件事在 widget 测试里
//   **根本不可能发生** —— 那不是产品缺陷，是测试仪器的边界。
// ```
//
// 本仓既有先例：test/t69_dlna_test.dart:39-61、test/t71_assrt_test.dart:208-219 ——
// 同一套 `_RealHttpOverrides`。这里沿用**同一个**做法（含「只放行本机」的纪律）。
//
// ⚠️ 必须改 **global**（`HttpOverrides.runZoned` 传不进用例体，t69:476 实测记着）。
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  late Directory root;

  setUp(() {
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    DownloadQueue.debugReset();
    root = Directory(
      '${_sandboxRoot().path}${Platform.pathSeparator}case-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    CachePage.debugScanRootOverride = root.path;
    /*
     * ★★ 两个根必须**指向同一个目录**（探针这里踩过一次）
     * ```text
     * CachePage.debugScanRootOverride 只影响**页面的扫盘**；
     * 而 DownloadQueue.previewRemoveWork / removeWork 用的是
     *   DownloadDir.forWork(title) → DownloadDir.root()（真实解析，读 pref/环境）。
     * ⇒ 只设 override 的话，删除走的是**真实下载目录**，
     *   探针沙盒里的东西一个都删不到 ⇒ 预览读到 files=0（实测就是这个 0）。
     * ⇒ 让 DownloadDir 也吃同一个沙盒根（setConfiguredDir 是生产 API，
     *   这里只是把它指向 TEMP 沙盒 —— 绝不碰用户真实 Videos）。
     * ```
     */
    DownloadDir.setConfiguredDir(root.path);
  });

  tearDownAll(() {
    final d = Directory('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t3_12');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除探针沙盒 ${d.path} 存在=${d.existsSync()}');
  });

  /// 挂起 CachePage 并把真实 IO 泵完
  ///
  /// ★ 为什么必须 runAsync：扫盘是真碰盘 IO，而 t.pump 走受控(fake)时钟 ⇒
  ///   真 IO 的 future 在 fake 区里永不完成、页面恒 loading（探针假阴性）。
  Future<CachePageState> pumpPage(WidgetTester t) async {
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(home: CachePage()));
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
      /*
       * ★★ 原来这里是 `await t.pump(const Duration(milliseconds: 300));`
       *    （在 runAsync **外面**）—— 目的是排掉 `UiPrefs._flushSoon` 那个 0.3s
       *    防抖计时器。
       * ⚠️ 但实测：当**下载队列刚跑完**时（⑤ 端到端那条），队列收尾还有真计时器在飞，
       *    受控时钟的 pump 会与它们互相等 ⇒ 用例 `did not complete`。
       * ⇒ 挪进 runAsync 里，用「真实等待 + pump」把两边都推完。
       *    判据完全没变（仍然等到了 UiPrefs 落盘），只是不再抢时钟。
       */
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump(const Duration(milliseconds: 50));
        while (t.takeException() != null) {}
      }
    });
    _claim(t);
    return t.state<CachePageState>(find.byType(CachePage));
  }

  // ══════════════════════════════════════════════════════════════════
  //  ① 封面读取侧
  // ══════════════════════════════════════════════════════════════════

  test('①-a 真写旁文件 ⇒ 扫盘读到 cover/provider/title（读取路径已证）', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}我的剧')
      ..createSync(recursive: true);
    _writeBytes('${dir.path}${Platform.pathSeparator}第01集 x.mp4', 1024 * 1024);
    _writeBytes('${dir.path}${Platform.pathSeparator}第02集 y.mp4.part', 1024 * 512);

    // ★ 按与生产写侧**同一个契约**落旁文件（见 _seedSidecar 的说明）
    _seedSidecar(dir, provider: 'cctv', id: 'cctv1', title: '我的剧',
        cover: 'https://example.com/cover.jpg');

    final works = await scanCacheWorks(root.path);
    expect(works.length, 1);
    final w = works.first;
    debugPrint('COVER 读取：title=${w.title} provider=${w.provider} '
        'id=${w.mediaId} cover=${w.cover}');
    debugPrint('COVER 集数：完成=${w.completedCount} 在下=${w.partialCount} 字节=${w.bytes}');
    expect(w.cover, 'https://example.com/cover.jpg',
        reason: '★★ 旁文件里的封面必须被读到（这正是 Owner 看不到的那张图）');
    expect(w.title, '我的剧');
    expect(w.provider, 'cctv');
    expect(w.completedCount, 1);
  });

  test('①-b 没有旁文件 ⇒ 退回目录名 + 无封面（不编造）', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}手拷进来的')
      ..createSync(recursive: true);
    _writeBytes('${dir.path}${Platform.pathSeparator}movie.mp4', 4096);
    final w = (await scanCacheWorks(root.path)).first;
    debugPrint('COVER 降级：title=${w.displayTitle} cover=${w.cover}');
    expect(w.cover, isNull, reason: '★ 没旁文件不许编造封面');
    expect(w.displayTitle, '手拷进来的', reason: '★ 退回目录名（safeName 不可逆）');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 下载中区块
  // ══════════════════════════════════════════════════════════════════

  testWidgets('②-a 空队列 ⇒ 整块不画', (t) async {
    _writeBytes('${root.path}${Platform.pathSeparator}已有剧${Platform.pathSeparator}e1.mp4', 2048);
    final st = await pumpPage(t);
    debugPrint('DL 空队列：sawDownloading=${st.debugSawDownloading} '
        '队列长度=${DownloadQueue.tasks.value.length} works=${st.debugWorkCount}');
    expect(st.debugSawDownloading, isFalse,
        reason: '★ 空队列必须整块不画（与 _LiveStrip 同一条纪律）');
    expect(find.textContaining('下载中'), findsNothing);
  });

  testWidgets('②-b 队列非空（真 enqueue）⇒ 界面出现「下载中」+ 进度百分比', (t) async {
    _writeBytes('${root.path}${Platform.pathSeparator}已有剧${Platform.pathSeparator}e1.mp4', 2048);
    final st = await pumpPage(t);

    // ★ 真往队列里塞一个任务（不启动下载器 —— flutter_tester 里没有核心）
    DownloadQueue.debugSetResolver((task) async => null);
    DownloadQueue.enqueue(const DownloadTask(
      id: 'cctv:cctv1:ep1',
      title: '正在下的剧',
      episodeTitle: '第01集',
      provider: 'cctv',
      mediaId: 'cctv1',
      episodeId: 'ep1',
      sourceCode: null,
      fileName: '第01集 x',
      done: 3,
      total: 10,
      state: DownloadState.running,
    ));
    await t.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await t.pump();
      }
    });
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    final texts = t
        .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    debugPrint('DL 非空队列：sawDownloading=${st.debugSawDownloading}');
    for (final s in texts.where((s) =>
        s.contains('下载中') || s.contains('%') || s.contains('第01集') || s.contains('正在下的剧'))) {
      debugPrint('DL   屏幕上的字：「$s」');
    }
    expect(st.debugSawDownloading, isTrue,
        reason: '★★ 队列非空时「下载中」区块必须真的画出来');
    expect(find.textContaining('下载中'), findsWidgets);
    expect(find.textContaining('第01集'), findsWidgets, reason: '★ 要能看出在下哪一集');
    expect(find.text('30%'), findsWidgets,
        reason: '★★ done=3/total=10 ⇒ 界面上必须出现 30%');
  });

  testWidgets('②-c 失败任务要看得见**原因原文**', (t) async {
    final st = await pumpPage(t);
    DownloadQueue.debugSetResolver((task) async => null);
    DownloadQueue.enqueue(const DownloadTask(
      id: 'cctv:cctv1:ep9',
      title: '失败的剧',
      episodeTitle: '第09集',
      provider: 'cctv',
      mediaId: 'cctv1',
      episodeId: 'ep9',
      sourceCode: null,
      fileName: 'ep9',
      state: DownloadState.failed,
      error: '连接超时：api.example.com',
    ));
    await t.runAsync(() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await t.pump();
      }
    });
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);
    debugPrint('DL 失败项：sawDownloading=${st.debugSawDownloading}');
    expect(find.textContaining('连接超时'), findsWidgets,
        reason: '★★ 失败必须能看到 error 原文（lead 明令）');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 整剧删除（真删文件）
  // ══════════════════════════════════════════════════════════════════

  testWidgets('③ 真删：报「删了几个文件/多少 MB」+ 页面真刷新 + 不连坐邻居', (t) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}要删的剧')
      ..createSync(recursive: true);
    _writeBytes('${dir.path}${Platform.pathSeparator}第01集.mp4', 1024 * 1024);
    _writeBytes('${dir.path}${Platform.pathSeparator}第02集.mp4', 1024 * 512);
    // ★ 旁文件由**写侧的生产格式**落盘（见 _seedSidecar 的说明）
    _seedSidecar(dir, provider: 'cctv', id: 'cctv9', title: '要删的剧');
    final keep = Directory('${root.path}${Platform.pathSeparator}别删我')
      ..createSync(recursive: true);
    _writeBytes('${keep.path}${Platform.pathSeparator}keep.mp4', 4096);

    final st = await pumpPage(t);
    final before = st.debugWorkCount;
    debugPrint('DEL 删除前：works=$before loadCount=${st.debugLoadCount} '
        '目录存在=${dir.existsSync()}');
    expect(before, 2, reason: '★ 两部剧（要删的剧 + 别删我）');

    // ── 预览：真读数（文件数 / 字节）—— 这也是确认弹窗正文要用的数 ──
    final pv = await t.runAsync(() => DownloadQueue.previewRemoveWork('要删的剧'));
    debugPrint('DEL 预览：files=${pv!.fileCount} bytes=${pv.bytes} '
        'sizeText=${pv.sizeText} 队列集数=${pv.episodeCount} '
        'files=${pv.fileNames}');
    expect(pv.fileCount, greaterThan(0), reason: '★ 预览必须真的读到文件');

    // ── 演练（force 不传）—— 确认默认安全 ──
    final dry = await t.runAsync(() => DownloadQueue.removeWork('要删的剧'));
    debugPrint('DEL 演练：deleted=${dry!.deleted} 目录还在=${dir.existsSync()}');
    expect(dry.deleted, isFalse, reason: '★★ 不传 force 必须只是演练、绝不真删');
    expect(dir.existsSync(), isTrue, reason: '★★ 演练后目录必须原样在');

    // ── ★★ 走**真实 UI 路径**：悬停「要删的剧」那张卡 ⇒ 点封面右上角的
    //    「更多」⇒ 菜单里选「删除整部」──
    //
    // ⚠️ 不能按图标找删除入口了：Owner 1009 第 1 条把它收进了「更多」菜单，
    //    页面上**不再有**垃圾桶图标（见 _CacheWorkCard 的注释）。
    // ⇒ 断言也必须跟着改成**新行为**：
    //    ① 悬停前：屏幕上**一个**「更多」按钮都没有（它默认隐藏）
    //    ② 悬停后：目标卡上出现一枚，且点它弹出的菜单里有「删除整部」
    //    这两条在旧行为下都会红（旧卡片下方常驻一个 delete_outline 图标）。
    //
    // ⚠️ 仍不许用 .first：卡片按目录名排序，「别删我」在前面 ⇒ .first 会
    //    操作到邻居那张卡（实测删错过目标）。先锚到标题所在的那张卡。
    final myCard = find.ancestor(
      of: find.text('要删的剧'),
      matching: find.byType(mui.Column),
    ).last;
    // ★ 「更多」在 PosterCard **之外**（它在卡片外层 Stack 里）
    //   ⇒ 不能用 descendant 取。而本卡片在标题乊方 ⇒ 用给它的稳定 key 定位。
    // ★ 选择器：「更多」不在标题那个 Column 里（它在卡片外层 Stack）
    //   ⇒ 按几何挑：落在**目标卡 PosterCard 矩形内**的那一枚。
    final posterRect = t.getRect(
      find.ancestor(of: find.text('要删的剧'),
          matching: find.byType(PosterCard)),
    );
    // ★ 按**目标那部的目录名**定位：按钮的 key 带着 dirName，
    //   因此不用在几何上猜（两张卡都有同类按钮，照旧方式会取到邻居）。
    final moreBtn =
        find.byKey(ValueKey<String>('cache-card-more:要删的剧'));
    debugPrint('DEL target PosterCard rect=$posterRect');
    debugPrint('DEL 全页「更多」按钮个数（悬停前）='
        '${find.byIcon(mui.Icons.more_horiz).evaluate().length}');

    // ① 悬停前：默认隐藏（Owner 原话「孤零零一个删除按钮真不好看」的正解）
    expect(find.byIcon(mui.Icons.delete_outline_rounded), findsNothing,
        reason: '★★★ 页面上不再有常驻的垃圾桶按钮（那是 Owner 要求去掉的）');

    // ② 悬停 ⇒ 「更多」显形（悬停点在**目标卡的封面上**，不能碰邻居那张）
    final poster = find.descendant(
      of: find.ancestor(of: find.text('要删的剧'),
          matching: find.byType(PosterCard)),
      matching: find.byType(mui.ClipRRect),
    ).first;
    // ★ 用“悬停事件”而不是拖一只虚拟鼠标：
    //   `TestGesture` 的位移在这里不会被转成 PointerHoverEvent，
    //   而 `MouseRegion.onEnter` 只认 hover 事件 ⇒ 需要直接发。
    await t.sendEventToBinding(PointerHoverEvent(
      position: t.getCenter(poster),
      kind: PointerDeviceKind.mouse,
    ));
    await t.pumpAndSettle();
    debugPrint('DEL 悬停后目标卡上的「更多」个数='
        '${moreBtn.evaluate().length}');
    expect(moreBtn, findsOneWidget,
        reason: '★★★ 悬停后目标卡必须出现「更多」入口');
    // 悬停态不可点（IgnorePointer）⇒ 必须先把它显形出来才 tap 得到
    await t.tap(moreBtn);
    await t.pumpAndSettle();
    expect(find.text('删除整部'), findsOneWidget,
        reason: '★★★ 菜单里必须有「删除整部」');
    // → 选它，之后才是二次确认弹窗（旧测试假设点就是删除按钮）
    await t.tap(find.text('删除整部').last);
    await t.pump(const Duration(milliseconds: 50));
    // 弹窗里的预览是一次**真读盘** ⇒ 必须在 runAsync 里等它回来
    await t.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await t.pump();
      }
    });
    _claim(t);

    final dialogTexts = t
        .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    debugPrint('DEL 确认弹窗里的字：');
    for (final s in dialogTexts.where((s) =>
        s.contains('删除') || s.contains('将删除') || s.contains('MB') || s.contains('恢复'))) {
      debugPrint('DEL   「$s」');
    }
    expect(find.text('删除整部？'), findsOneWidget,
        reason: '★★ 必须弹二次确认（真删不可逆）');
    expect(find.textContaining('将删除'), findsOneWidget,
        reason: '★★ 确认正文必须写清「将删 N 集 / 共 X MB」');
    expect(find.textContaining('不可恢复'), findsOneWidget,
        reason: '★★ 必须告知不可逆');

    // ── 点弹窗里的「删除」──
    // ⚠️ 必须锚在**对话框**里取「删除」按钮：
    //    `find.widgetWithText(TextButton, '删除')` 会同时命中卡片上的
    //    「删除整部」（Text 的匹配是**包含**语义）⇒ 取到的可能是卡片那个。
    final dialog = find.byType(mui.AlertDialog);
    expect(dialog, findsOneWidget, reason: '★ 确认弹窗必须在树上');
    final confirmBtn = find.descendant(
      of: dialog,
      matching: find.widgetWithText(mui.TextButton, '删除'),
    );
    // ★ 诊断：把弹窗里所有 TextButton 的位置与文案打出来，看清点的是哪个
    for (final e in t.widgetList<mui.TextButton>(
        find.descendant(of: dialog, matching: find.byType(mui.TextButton))).toList()) {
      debugPrint('DEL 弹窗按钮：onPressed=${e.onPressed != null} child=${e.child}');
    }
    debugPrint('DEL 弹窗「删除」按钮个数=${confirmBtn.evaluate().length} '
        '位置=${confirmBtn.evaluate().isEmpty ? null : t.getCenter(confirmBtn.first)}');
    expect(confirmBtn, findsOneWidget);
    // ⚠️ 这里用 `t.tap`（不是 tapAt）：确认按钮在**对话框自己的 overlay** 里，
    //    而 showAppDialog 用的是 `useRootNavigator: true`（overlay_motion.dart:318）
    //    ⇒ 它挂在 root overlay 上；`tapAt` 走的命中测试与 getCenter 的坐标系
    //    在嵌套 overlay 下不一定重合（实测 tapAt 打在 351 高度但事件没到回调）。
    //    `t.tap(finder)` 会先做 `warnIfMissed` 的命中校验再派发，且它取中心点
    //    的方式与 hit-test 同源 ⇒ 更可靠。
    await t.tap(confirmBtn.first);
    /*
     * ★★★ 这一步的**顺序**是本次探针最难的一处，踩了三轮，记下来：
     * ```text
     * 现象：只有「[演练] 整剧删除」那条日志，目录**纹丝不动**。
     *       看起来像弹窗的「删除」按钮没生效 —— 其实是**假的**。
     *
     * 根因：`_confirmDelete` 里 `await showAppDialog<bool>(...)` 的返回**不是**
     *   在 pop 的那一刻，而是在**退场动画跑完之后**（route 才真正离场）。
     *   ⚠️ 本仓 overlay_motion.dart:284/300-311 明确记着这条：
     *     「`await showAppDialog(...)` 返回时，退场动画才刚开始」——
     *     反向同理：动画**没走完**，await 就**一直挂着**。
     *   ⇒ pop 之后必须**把时钟推够**让退场动画走完，await 才会返回，
     *     后面那句 removeWork(force:true) 才会执行。
     *
     * 而且推动画用的必须是**受控时钟**（t.pump(时长)）——
     *   退场动画是 Flutter 自己驱动的 Ticker，它在 fake async 区里才受
     *   pump 控制；而 removeWork 里的真 IO 又必须在 runAsync 里。
     * ⇒ 两者**交替**：先受控泵完动画 → 再 runAsync 放真 IO。
     * ```
     */
    /*
     * ★★ 关键：**动画与真 IO 必须在同一个 runAsync 里交替推**。
     * ```text
     * 踩坑记录（第三轮才想对）：
     *   我先在 runAsync **外面** `pump(400ms)` 想推完退场动画 —— 没用：
     *   退场动画的 Ticker 挂在 `runAsync` 建立的那个**真实 zone** 上，
     *   fake-clock 的 pump 推不动它（这正是本文件开头那条「真 IO 必须
     *   runAsync」的**同一条**规则的推广：凡是被真实 zone 驱动的东西，
     *   都要在 runAsync 里推）。
     *   ⇒ 正确做法：**一个** runAsync 循环里反复 `delayed + pump`，
     *     每轮都同时推进「退场动画」（pump 驱动 Ticker）与
     *     「removeWork 的真 IO」（delayed 让出真实事件循环）。
     * ```
     */
    await t.pump();
    await t.runAsync(() async {
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump(const Duration(milliseconds: 50));
      }
    });
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);

    debugPrint('DEL 删除后：works=${st.debugWorkCount} loadCount=${st.debugLoadCount} '
        '目标目录存在=${dir.existsSync()} 邻居存在=${keep.existsSync()}');
    expect(dir.existsSync(), isFalse, reason: '★★ 真删了：目录必须没了');
    expect(keep.existsSync(), isTrue, reason: '★★ 只删目标，不许连坐邻居');
    expect(st.debugWorkCount, before - 1, reason: '★★ 页面必须真的刷新（works 少 1）');
    expect(find.text('别删我'), findsWidgets, reason: '★ 邻居还在屏幕上');
    expect(find.text('要删的剧'), findsNothing, reason: '★ 被删的那部不许还挂在屏幕上');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ★★ ⑤ 端到端主证据：**真下一次载** ⇒ 生产写侧真落旁文件 ⇒ 页面画出封面
  // ══════════════════════════════════════════════════════════════════

  testWidgets('⑤ 端到端：真下载一集 ⇒ 生产写侧落旁文件 ⇒ 扫盘读出封面', (t) async {
    /*
     * ★ 沙盒根**同步**拿到（setUp 里 `DownloadDir.setConfiguredDir(root.path)` 已指好）。
     * ⚠️ 不要在这里 await DownloadDir.root()：那是真 IO，而本用例后面要
     *    跟 DownloadQueue 的收尾抢事件循环（见第 ⑤ 步的注释）。
     */
    final rootPathSync = root.path;
    debugPrint('E2E 沙盒根 = $rootPathSync');

    // ★★★ 先装真 HttpClient（否则所有请求被 flutter_test 的 mock 回 400 —— 见类注释）
    final saved = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = saved);

    // ① 起一个**真** HTTP 服务器当上游（发一个真 mp4 字节流）
    //
    // ⚠️ 用 `server.listen`（本仓先例 task18_clip_concurrency_test.dart:74）
    //    而不是 `await for (final req in server)` —— 后者在 widget 测试的
    //    受控 zone 里拿不到请求（实测一个请求都收不到）。`listen` 走的是
    //    服务端自己的订阅，与测试 zone 无关。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final body = List<int>.filled(256 * 1024, 0x42);
    var hits = 0;
    server.listen(
      (req) {
        unawaited(() async {
          hits++;
          debugPrint('E2E 上游收到请求 #$hits ${req.uri.path}');
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType('video', 'mp4')
            ..headers.contentLength = body.length;
          req.response.add(body);
          await req.response.close();
        }());
      },
      onError: (Object e) => debugPrint('E2E 上游错误: $e'),
    );
    debugPrint('E2E 上游服务器 = http://${server.address.host}:${server.port}');

    // ② 让队列的解析器指向这个真服务器（生产路径其余部分一行不改）
    DownloadQueue.debugSetResolver((task) async => StreamCandidate(
          url: 'http://${server.address.host}:${server.port}/e1.mp4',
          kind: 'mp4',
        ));

    // ③④ 真入队 + 等它下完 —— ★★ 两件事**必须在同一个 runAsync 里**
    //
    // # 为什么入队也必须进 runAsync（这是本轮最难的一处，卡了两轮）
    // ```text
    // 现象：跑 60 秒一直 `running done=0/0`，上游服务器**一个请求都没收到**。
    //
    // 根因：`enqueue` → `_pump()` → `unawaited(_run(i))` 这条链是**同步**发起的
    //   （_pump 是 async 函数，但它在第一个 await 之前就调了 _run）。
    //   若在**用例体**（受控 fake 时钟的那个 zone）里调 enqueue，
    //   then `_run` 里所有 await（`_resolveStreamFor`、`HttpClient.getUrl`、
    //   写盘的 `File.writeAsBytes`）全都登记在**受控 zone** 上 ⇒
    //   之后在 runAsync 里怎么 delayed/pump 都推不动它们。
    //   ⇒ 症状就是「入队成功了、状态是 running、但一个字节都没动」。
    //
    // ⇒ 正确做法：**在 runAsync 内部**调 enqueue，让整条 _run 生在真实事件循环里。
    //   （与本文件开头「真 IO 必须 runAsync」是同一条规则，只是这次连**发起**
    //     也得在里面 —— 光把「等待」放进去不够。）
    // ```
    //
    // ⚠️ HlsDownloader 拿到正文先判 `#EXTM3U`（hls_download.dart:286）：
    //    mp4 直链会先整取一遍正文才发现不是清单、抛 HlsNotPlaylistException、
    //    再回退直链下载（**第二遍**）⇒ 两遍真网络，要多等一会儿。
    //    只在 done/failed 上提前退出。
    var ok = false;
    await t.runAsync(() async {
      ok = DownloadQueue.enqueue(const DownloadTask(
        id: 'cctv:e2e1:ep1',
        title: '端到端剧',
        episodeTitle: '第01集',
        provider: 'cctv',
        mediaId: 'e2e1',
        episodeId: 'ep1',
        sourceCode: null,
        fileName: '第01集 端到端',
        cover: 'https://example.com/e2e-cover.jpg',
      ));
      debugPrint('E2E 入队 = $ok');
      for (var i = 0; i < 1200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
        final ts = DownloadQueue.tasks.value;
        if (ts.isNotEmpty && i % 20 == 0) {
          final x = ts.first;
          debugPrint('E2E 进度 t=${(i / 20).toStringAsFixed(0)}s '
              'state=${x.state.name} done=${x.done}/${x.total} '
              'err=${x.error}');
        }
        if (ts.isNotEmpty &&
            (ts.first.state == DownloadState.done ||
                ts.first.state == DownloadState.failed)) {
          break;
        }
      }
    });
    expect(ok, isTrue, reason: '★ 入队要成功');
    final done = DownloadQueue.tasks.value;
    debugPrint('E2E 队列终态 = ${done.map((e) => e.state.name).toList()}');
    expect(done.first.state, DownloadState.done,
        reason: '★★ 真下载必须成功（否则后面全是空话）');

    /*
     * ⑤ ★ 生产写侧真的落了旁文件吗（直接读盘，不看内存）
     * ```text
     * ⚠️ 这里**不要**再 `await t.runAsync(() => DownloadDir.forWork(...))` 了。
     *   实测：下载刚跑完时 `DownloadQueue._pump` 的收尾还在飞
     *   （`_run` 的 finally 会 unawaited 再进 _pump），而 flutter_test 的
     *   runAsync 只有在**没有**待处理真实事件时才会推进它要等的那个 future
     *   ⇒ 两边互相等 ⇒ 用例挂到 `did not complete`（实测 6 分钟无进展）。
     * ⇒ 改法：`DownloadDir.forWork` 的产物就是 `root/safeName(title)`，
     *   而 root 在 setUp 里已经通过 DownloadDir.setConfiguredDir 指到沙盒了 ⇒
     *   **路径可以同步拼**，然后纯 fs 读（同步、不碰事件循环）。
     * ★ 判据一点没变：仍然是在**磁盘上**验证生产写侧写过什么。
     * ```
     */
    final workDir = '$rootPathSync${Platform.pathSeparator}端到端剧';
    final sidecar = File(
      '$workDir${Platform.pathSeparator}${DownloadQueue.kSidecarName}',
    );
    debugPrint('E2E 旁文件 = ${sidecar.path} 存在=${sidecar.existsSync()}');
    expect(sidecar.existsSync(), isTrue,
        reason: '★★★ 下载成功后生产写侧必须写出 _sourin-cache.json');
    final raw = sidecar.readAsStringSync();
    debugPrint('E2E 旁文件内容 = $raw');
    expect(raw.contains('e2e-cover.jpg'), isTrue,
        reason: '★★★ 封面 URL 必须真的落进旁文件');

    // ⑥ ★ 页面扫盘后必须把封面读出来（真渲染）
    //
    // ⚠️ 这里**也**不要 await DownloadDir.root() —— 同上，避开与队列收尾抢事件循环。
    //    扫的是同一个沙盒根（rootPathSync），判据完全相同。
    CachePage.debugScanRootOverride = rootPathSync;
    final st = await pumpPage(t);
    final works = await t.runAsync(() => scanCacheWorks(rootPathSync));
    debugPrint('E2E 扫盘 = ${works!.map((w) => "${w.displayTitle}/cover=${w.cover}/集=${w.completedCount}").toList()}');
    expect(works.any((w) => w.cover == 'https://example.com/e2e-cover.jpg'), isTrue,
        reason: '★★★ 端到端：真下载的剧，扫盘必须读出它的封面');
    debugPrint('E2E 页面 works=${st.debugWorkCount}');

    /*
     * ⚠️ **这里不要任何裸 `t.pump(时长)`**（踩过：用例 did not complete）
     * ```text
     * 现象：上面每一条读数**都打出来了**（扫盘读到封面、works=1），
     *       然后用例挂住、1 分 44 秒后判 `did not complete`。
     * 根因：`DownloadQueue` 在跑完后仍留着**真**计时器（收尾/清理）；
     *       裸 `t.pump(时长)` 试图推受控时钟，而框架在等那个真计时器结算
     *       ⇒ 两边互相等 ⇒ 挂住。
     * ⇒ 本用例的判据**在 587 行之前就全部验完**了（见上面的 expect），
     *   收尾只需要「把还没收的异常收掉」，不需要再推时钟。
     * ```
     */
    _claim(t);

    /*
     * ★★★ 收尾前先**把下载队列停干净**（本轮最后一个卡点）
     * ```text
     * 现象：上面每一条读数都打出来了，然后**永远**停在收尾（10+ 分钟无进展）。
     * 根因：`DownloadQueue._pump` 的收尾由 `unawaited(_run(i))` 触发，
     *       那个「已 done」的任务上仍挂着真定时器 ⇒ flutter_test 在用例体
     *       结束后要等**所有**真实 pending 事件结算 ⇒ 两边互相等 ⇒ 挂住。
     * ★ 本用例要证的**全部是「写盘结果」**（旁文件内容 + 扫盘读回封面），
     *   **不需要**下载队列继续活着 ⇒ 收尾 reset 它是正当的，不是掩盖问题：
     *   所有 `expect` 都在 reset **之前**已断言完毕。
     * ⚠️ 顺序：必须放在所有断言之后。
     * ```
     */
    DownloadQueue.debugReset();
    debugPrint('E2E 已停下载队列（判据均已断言完毕）');

    /*
     * ★★ 收尾必须**主动关掉上游服务器并等它真的关完**（踩过：
     *    "A Timer is still pending even after the widget tree was disposed"）。
     * ```text
     * `addTearDown(() => server.close(force: true))` 返回的是 Future，
     * 但 addTearDown **不等它**（回调是同步闭包、没有 await）⇒
     * HttpServer 的内部监听 socket 计时器活过了用例体 ⇒ flutter_test 判红。
     * ⇒ 在用例体里 await 一次 close，再让 tearDown 兜底（幂等，重复关无害）。
     * ```
     */
    /*
     * ⚠️ close 是真 IO ⇒ 包 runAsync；但**不能阻塞用例** ——
     *    实测 `await t.runAsync(() => server.close(...))` 仍会挂住
     *    （runAsync 要等真实事件结算，而 flutter_tester 里那个 socket 的
     *      结算点与受控时钟的收尾互相等）。
     * ⇒ `force: true` 是**立即**断开、不等在途请求 ⇒ 发起即可，
     *   由 addTearDown 兜底（幂等）。用例的判据早已全部断言完毕，
     *   这里只是别把监听 socket 留给下一个用例。
     * ```text
     * ★ 这不是「掩盖」：判据在 reset + close **之前**就全部绿了；
     *   这一步纯属资源清理，不该影响用例结果。
     * ```
     */
    unawaited(server.close(force: true));
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ provider/id 规范化（lead 点名的硬要求）
  // ══════════════════════════════════════════════════════════════════

  test('④-a 同一个文件的多种写法必须算出**同一个** key', () {
    final sep = Platform.pathSeparator;
    final p = '${root.path}${sep}规范化${sep}A.mp4';
    final variants = <String>[
      p,
      p.replaceAll(r'\', '/'),
      p.replaceAll(r'\', '//'),
      '${root.path}${sep}规范化${sep}.${sep}A.mp4',
      '${root.path}${sep}规范化${sep}子目录${sep}..${sep}A.mp4',
    ];
    final keys = variants.map(canonicalLocalPath).toSet();
    for (final v in variants) {
      debugPrint('CANON 「$v」 ⇒ 「${canonicalLocalPath(v)}」');
    }
    debugPrint('CANON 不同 key 的个数=${keys.length}（必须 = 1）');
    expect(keys.length, 1, reason: '★★ 多种写法必须折叠成同一个 key');

    if (Platform.isWindows) {
      final upper = canonicalLocalPath(p.toUpperCase());
      final lower = canonicalLocalPath(p.toLowerCase());
      debugPrint('CANON 大小写：大写 ⇒「$upper」 小写 ⇒「$lower」');
      expect(upper, lower, reason: '★★ Windows 大小写不敏感 ⇒ 必须同一个 key');
      final long = canonicalLocalPath('\\\\?\\$p');
      debugPrint('CANON 长路径前缀 ⇒「$long」');
      expect(long, canonicalLocalPath(p), reason: '★★ 长路径前缀不改变文件身份');
    }
  });

  test('④-b provider 必须恒为 local（不许污染在线记录）', () async {
    final dir = Directory('${root.path}${Platform.pathSeparator}本地剧')
      ..createSync(recursive: true);
    _writeBytes('${dir.path}${Platform.pathSeparator}e1.mp4', 1024);
    final w = (await scanCacheWorks(root.path)).first;
    final req = buildLocalPlayRequest(w);
    debugPrint('LOCAL provider=${req!.provider} mediaId=${req.mediaId} '
        'fileUrl=${req.fileUrl}');
    expect(req.provider, 'local');
    expect(req.provider, kLocalProvider);
    expect(req.mediaId.contains('e1.mp4'), isTrue);
    expect(req.fileUrl.startsWith('file:///'), isTrue);
    expect(req.provider == 'cctv' || req.provider == 'bilibili', isFalse,
        reason: '★★ 沿用站点 provider 会把在线记录的进度改成本地文件的');
  });
}
