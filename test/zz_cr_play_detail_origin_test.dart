import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart' show CachedEpisode, CachedWork;
import 'package:sourin_spike/ui/detail_page.dart';

// CR-12 回归测试：认回来源之后，本地详情页的封面和离线元数据必须还在。
//
// 缺陷（lib/ui/detail_page.dart _loadLocalOrigin 末尾，CR 提出时 1446-1453）：
//
//     final c = hit.cover;
//     if (c != null && c.isNotEmpty) {
//       _detail = MediaDetail(id: …, title: …, cover: c);   // ← 只剩三个字段
//     }
//
// 认回来源那一瞬间，MediaDetail 被整个换掉，_initLocal 刚铺好的
// description / year / area / kind / badges 一起消失，本地封面路径也被换成了
// 记录里的网络图 URL。业主的反馈就是这个：本地播放详情页的封面和「来源」要保留。
//
// 为什么必须加注入点（lib/ui/detail_page.dart 里的 debugSetLocalOriginRecords）：
//   命中记录来自 SourinApi.listAllProgress() / listFavorites()，两者在
//   flutter_tester 里必然抛「Failed to load dynamic library 'sourin_core.dll'」
//   （error code: 126），catch 之后返回 null ⇒ 永远造不出「带 cover 的命中」。
//   没有这个口子，CR-12 就只能靠人眼看，属于假门禁。
//
// 尺子说明：整份文件只看真实渲染树 ——
//   · 封面：detail_page.dart 里除了 Image.file 和 coverImage(=Image.network)
//     没有别的 Image，所以「页面上 Image 的 provider 是 FileImage 还是
//     NetworkImage」就是「这一页的封面被认成哪种来源」。注意要剥 ResizeImage。
//   · 简介/徽章：_Info._rest 只在 description 非空时渲染简介；
//     _Info._head 渲染 detail.badges。
//   · 「来源」：_localOrigin 由 providerDisplayName(hit.provider) 填，
//     在 flutter_tester 里它会退化成 provider id 本身，所以断言 'cycani'。
//
// 对照组那一组是尺子自检：它把 detail 换成一个空壳，证明上面的正面断言
// 在缺陷形态下真的会红（简介/徽章找不到、封面 provider 读成 none）。
//
// 跑法：flutter test test/zz_cr_play_detail_origin_test.dart --reporter expanded --concurrency=1

/// 1x1 透明 PNG：只为让「文件真的存在」这句话成立
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQ'
    'AAAABJRU5ErkJggg==';

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

const double _panelW = 433.0;
const double _panelH = 900.0;

final String _bs = String.fromCharCode(92);

/// C:\Users\IU\Videos\sourin —— 两条用例共用，避免路径散落
// ignore: unnecessary_brace_in_string_interps
final String _localDir =
    'C:${_bs}Users${_bs}Videos${_bs}sourin';
final String _epFile = '$_localDir$_bs第01集.mp4';

const String _title = '测试影片';
const String _intro = '这是一条只有本地才有的简介。';
const String _badge = '已完结';
const String _netCover = 'https://img.example.com/a.jpg';

/// 把 owner 报告的那一幕造出来：磁盘上真有一张本地封面
late Directory _tmp;
late String _realCover;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: mui.Scaffold(body: mui.Material(child: child)),
  );
}

/// 页面上唯一的 Image 是本地还是网络（判据见文件头）
String _coverKind(WidgetTester tester) {
  final imgs = tester.widgetList<Image>(find.byType(Image)).toList();
  if (imgs.isEmpty) return 'none';
  final kinds = <String>{};
  for (final i in imgs) {
    final p = _unwrap(i.image);
    if (p is FileImage) {
      kinds.add('file');
    } else if (p is NetworkImage) {
      kinds.add('network');
    } else {
      kinds.add(p.runtimeType.toString());
    }
  }
  return kinds.length == 1 ? kinds.first : 'mixed(${kinds.join('+')})';
}

/// 剥掉 cacheWidth 带来的 ResizeImage 外壳
ImageProvider _unwrap(ImageProvider p) {
  var cur = p;
  for (var i = 0; i < 4; i++) {
    if (cur is ResizeImage) {
      cur = cur.imageProvider;
    } else {
      return cur;
    }
  }
  return cur;
}

/// 挂一次真 DetailPage（本地文件模式），让 _initLocal 自己跑完
///
/// ★ 为什么不注入 detail：CR-12 的整条链是
///   `_initLocal` 铺 meta → `_loadLocalOrigin` 认回来源 → **顺手把 _detail 换掉**；
///   注入 detail 就等于把被测的那一步摘掉了。
Future<void> _mountLocal(WidgetTester tester) async {
  NetworkStatus.debugProbe = () async => false;
  addTearDown(NetworkStatus.debugResetForTest);
  await tester.binding.setSurfaceSize(const Size(_panelW, _panelH));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(_host(
    DetailPage(
      provider: 'local',
      id: _realCover,
      embedded: true,
      localFile: _epFile,
      localTitle: _title,
      localEpisodeCount: 1,
      localMeta: CachedWork(
        dirName: _title,
        path: _localDir,
        episodes: const <CachedEpisode>[],
        localCoverPath: _realCover,
        description: _intro,
        badges: const <String>[_badge],
      ),
    ),
  ));
  _claim(tester);
  // _initLocal 是 unawaited 的（initState:1226），只能 pump 出它的将来
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    _claim(tester);
  }

  // ★★ 必须借一次**真**事件循环，否则「来源」chip 永远亮不起来。
  //
  //   _loadLocalOrigin 认回来源之后会 `await providerDisplayName(hit.provider)`，
  //   而那个函数内部走 `SourinApi.listProviders()` → `SourinCore.callAsync`，
  //   回包由 `NativeCallable.listener` 经**真**消息端口投递。
  //   而 testWidgets 的函数体跑在 `FakeAsync` 里 —— 假时钟下真事件循环不转，
  //   回包送不进来 ⇒ 那个 future 看起来"永不完成"，`_localOrigin` 一直是兜底的
  //   「本地」⇒ 断言 'cycani' 找不到（Found 0 widgets）。
  //
  //   `tester.runAsync` 把一段代码放回真事件循环执行 ⇒ 回包送达；之后那次
  //   `pump` 再冲刷 fake zone 的微任务队列，续体才跑得起来。
  //
  //   ★ 这是**测量方式**的修正，不是产品行为：test/zz_cr_origin_probe3_test.dart
  //     实测真循环下它**立刻**回一个「核心尚未启动」的异常，函数随即退化成
  //     裸 provider id（所以在 flutter_tester 里断言的是 'cycani' 而不是中文站名）。
  //     探针 1/2 曾在只泵假时钟下量到"永不完成"并据此判过"结构性不可达"，
  //     那个结论已被探针 3 推翻（见那两个文件头的纠错横幅）。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  for (var i = 0; i < 2; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    _claim(tester);
  }
}

/// 装上 progress/favorites 两张表：一条**带网络封面**的命中记录
void _installRecords({String recordTitle = _title, String? cover = _netCover}) {
  debugSetLocalOriginRecords(() => (
        progress: <Progress>[
          Progress(
            key: 'cycani:m1',
            provider: 'cycani',
            nativeId: 'm1',
            title: recordTitle,
            cover: cover,
            updatedAt: 10,
          ),
        ],
        favorites: const <Favorite>[],
      ));
  addTearDown(() => debugSetLocalOriginRecords(null));
}

void main() {
  // 磁盘上真的放一张本地封面 —— owner 报告的就是「文件在、页面不显示」
  setUpAll(() {
    _tmp = Directory.systemTemp.createTempSync('sourin_cr12');
    // ★ OPS-18：同 zz_cr_play_detail_cover_test.dart —— `$_bs\\` 拼出两个反斜杠
    //   （不存在的子目录）⇒ POSIX 上 writeAsBytesSync 抛 FileSystemException。
    final f = File('${_tmp.path}${Platform.pathSeparator}_sourin-cover.jpg');
    f.writeAsBytesSync(base64Decode(_pngBase64));
    _realCover = f.path;
  });
  tearDownAll(() {
    /*
     * ★ OPS-18：删临时目录是**尽力而为**，不是判据。
     * ```text
     * 实测（Windows，不退出 ImageCache 时）：
     *   PathAccessException: Deletion failed, path = '…\sourin_cr12…'
     *   (OS Error: 另一个程序正在使用此文件，进程无法访问。, errno = 32)
     * ⇒ 测试用例全部通过，却以 `(tearDownAll) [E]` + `Some tests failed.` 收尾
     *   ⇒ CI 看起来是红的，而真正的原因只是图片还没被释放。
     * 与 CR-12 本身毫无关系 ⇒ 先逐出图片，再重试几次，最后才安全吞掉。
     * ```
     */
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {
      // binding 已经拆了也无所谓 —— 下面还有重试
    }
    for (var i = 0; i < 5; i++) {
      try {
        if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
        return;
      } on FileSystemException catch (e) {
        debugPrint('CLEANUP 第 ${i + 1} 次删除失败（文件仍被占用，与用例无关）: $e');
        sleep(const Duration(milliseconds: 200));
      }
    }
    debugPrint('CLEANUP 残留临时目录 ${_tmp.path}（系统会自行回收，不影响判据）');
  });

  // ============================================================
  //  0  仪器自检
  // ============================================================
  group('0 self-check (anti false-green)', () {
    testWidgets('* the local cover really is on disk and really renders as file',
        (tester) async {
      print('CR12|local cover path = $_realCover'); // ignore: avoid_print
      expect(File(_realCover).existsSync(), isTrue);
      debugSetLocalOriginRecords(() => (
            progress: const <Progress>[],
            favorites: const <Favorite>[],
          ));
      addTearDown(() => debugSetLocalOriginRecords(null));
      await _mountLocal(tester);
      expect(find.text(_title), findsOneWidget);
      expect(_coverKind(tester), 'file',
          reason: '没有命中记录时，localMeta 铺的本地封面必须显示');
      expect(find.text(_intro), findsOneWidget);
      expect(find.text(_badge), findsOneWidget);
    });
  });

  // ============================================================
  //  CR-12 本身
  // ============================================================
  group('CR-12 binding the origin back must not wipe the local metadata', () {
    testWidgets('* local cover survives a hit that carries a network cover',
        (tester) async {
      _installRecords();
      await _mountLocal(tester);
      expect(find.text(_title), findsOneWidget);
      expect(_coverKind(tester), 'file',
          reason: 'record cover is $_netCover, but the local cover file is really on disk; swapping it for the network URL is the defect');
      expect(find.text(_intro), findsOneWidget,
          reason: 'localMeta.description was laid down by _initLocal');
      expect(find.text(_badge), findsOneWidget,
          reason: 'localMeta.badges was laid down by _initLocal');
      expect(find.text('已下载 1 集'), findsOneWidget);
    });

    // ★ 把「元数据被抹掉」这一半单独拎出来一条：上面那条先在封面断言上就红了，
    //   断言链后面的简介/徽章根本走不到 ⇒ 缺陷的另一半必须有独立证据。
    testWidgets('* intro and badges survive the same hit (metadata half)',
        (tester) async {
      _installRecords();
      await _mountLocal(tester);
      expect(find.text(_intro), findsOneWidget,
          reason: 'record hits, and that hit rebuilds MediaDetail; the local '
              'description laid down by _initLocal must not be dropped');
      expect(find.text(_badge), findsOneWidget,
          reason: 'same for localMeta.badges');
      expect(find.text('已下载 1 集'), findsOneWidget);
    });
    testWidgets('* origin still shows the real provider name', (tester) async {
      _installRecords();
      await _mountLocal(tester);
      expect(find.text('cycani'), findsOneWidget,
          reason: '认回来源这一条行为不能被上面的修复顺带弄丢');
    });

    testWidgets('a hit without a cover does not change the cover either',
        (tester) async {
      _installRecords(cover: null);
      await _mountLocal(tester);
      expect(_coverKind(tester), 'file');
      expect(find.text(_intro), findsOneWidget);
    });
  });

  // ============================================================
  //  对照组：证明尺子抓得到缺陷
  // ============================================================
  group('CR-12 control (ruler sanity)', () {
    testWidgets('* a wiped detail really does lose the intro (same ruler)',
        (tester) async {
      // 直接注入一个「什么都没有」的详情 —— 它就是修复前那一刻的界面形状
      NetworkStatus.debugProbe = () async => false;
      addTearDown(NetworkStatus.debugResetForTest);
      await tester.binding.setSurfaceSize(const Size(_panelW, _panelH));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<State<DetailPage>>();
      await tester.pumpWidget(_host(
        DetailPage(
          key: key,
          provider: 'local',
          id: 'local',
          embedded: true,
          localFile: _epFile,
          localTitle: _title,
          localMeta: CachedWork(
            dirName: _title,
            path: _localDir,
            episodes: const <CachedEpisode>[],
            localCoverPath: _realCover,
            description: _intro,
            badges: const <String>[_badge],
          ),
        ),
      ));
      _claim(tester);
      await tester.pump();
      _claim(tester);
      // ignore: avoid_dynamic_calls
      (key.currentState! as dynamic)
          .debugSetDetail(const MediaDetail(id: 'local', title: _title));
      await tester.pump();
      _claim(tester);
      expect(find.text(_intro), findsNothing,
          reason: 'a detail with no description renders none — so the positive assertion above really can fail');
      expect(find.text(_badge), findsNothing);
      expect(_coverKind(tester), 'none',
          reason: 'and no cover at all — the wiped state is reachable and observable, which is what makes the fix testable');
    });
  });
}

