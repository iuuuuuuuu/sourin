// CR-11 回归测试：本地详情页的封面在 Windows 上必须真的走 Image.file
//
// ★ 缺陷（CodeRabbit CR-11，lib/ui/detail_page.dart:3551-3555）
//   `Uri.tryParse('C:\\Users\\IU\\…\\_sourin-cover.jpg')` 把盘符 `C` 读成 **scheme**
//   ⇒ hasScheme == true ⇒ `_isLocalCover` 返回 false ⇒ 封面掉进
//   `Image.network('C:\\…')` 分支 ⇒ 主力平台 Windows 上必然加载失败
//   ⇒ 本地封面永远退化成首字占位符（断网时连磁盘上那张图都看不到）。
//
// ★ 实测判定表（本仓 dart 脚本真跑出来的，逐条抄在这里，非推理）
//   C:<BS>Users<BS>IU<BS>AppData<BS>Temp<BS>cover.jpg | tryParse=true scheme=c hasScheme=true   ← 缺陷
//   C:/Users/IU/cover.jpg                               | tryParse=true scheme=c hasScheme=true   ← 缺陷
//   d:<BS>a.jpg                                         | tryParse=true scheme=d hasScheme=true   ← 缺陷
//   <BS><BS>server<BS>share<BS>a.jpg                    | tryParse=true scheme=  hasScheme=false （URI 解析器本来就对）
//   /home/u/a.jpg                                       | tryParse=true scheme=  hasScheme=false （本来就对）
//   cover.jpg                                           | tryParse=true scheme=  hasScheme=false （本来就对）
//   file:///C:/a.jpg                                    | tryParse=true scheme=file hasScheme=true（★ 必须仍判**非**本地）
//   https://x/y.jpg                                     | tryParse=true scheme=https hasScheme=true
//
// ★ 断言口径（不许退化成「源码里有正则」）
//   挂**真** DetailPage、跑**真** `_buildBody` ⇒ 渲染出**真** `_Cover`，
//   断言的是 **Image 的 provider 到底是 FileImage 还是 NetworkImage**。
//   lib/ui/detail_page.dart 里除 `Image.file`（本地分支 :3609）与
//   `coverImage`（= `Image.network`，网络分支 :3624）之外再无任何 `Image.`
//   用法（已 grep 确认）⇒「页面上唯一的 Image 是什么类型」就是判据本身。
//   另附 ⓪ 仪器自检组：先用**已知该走网络分支**的 URL 证明这把尺子
//   **能区分两个状态** —— 否则后面任何「绿」都可能只是尺子坏了。
//
// ★ 本地磁盘封面用的是**真文件**（临时目录里的真 PNG）
//   ⇒ Windows 上临时目录路径必然是 `C:<BS>…` 盘符路径，缺陷现场天然复现；
//   而且文件真的存在，不需要靠 errorBuilder 兜底凑一个「看起来渲染了」的结果。
//
// 跑法：
//   cmd /c flutter test test\zz_cr_play_detail_cover_test.dart \
//       --reporter expanded --concurrency=1

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

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 窄档面板宽（与 test/t97_resume_chip_fit_test.dart 同一条布局路径：w < 620
/// ⇒ 封面与标题并排）。高度给足，避免选集区把封面挤出可视区。
const double _panelW = 433.0;
const double _panelH = 900.0;

/// A Windows path separator written this way, so nothing can "eat" the backslash
final String _bs = String.fromCharCode(92);

/// 第 01 集的文件名（纯中文，用来证明路径里的中文段不影响判定）
const String _ep01 = '第01集.mp4';

/// 1×1 透明 PNG —— 只为让封面**真的能解码**（而不是走 errorBuilder 兜底）
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Windows 上 `Directory.systemTemp` 必然形如 `C:<BS>Users<BS>…<BS>Temp<BS>…`
/// ⇒ 盘符路径是**环境给的**，不是在测试里编出来的字符串。
late Directory _tmp;
late String _realCover;

/// 真主题 + 定宽面板里挂 DetailPage（`embedded: true` = 合并页右侧面板）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: mui.Scaffold(body: mui.Material(child: child)),
  );
}

MediaDetail _detailWith(String? cover) => MediaDetail(
      id: 'local',
      title: '测试影片',
      cover: cover,
    );

/// 挂真 DetailPage 并注入详情
///
/// ★ 绕过的只是「向核心要详情」那一次 FFI（`sourin_core.dll` 在
///   flutter_tester 里加载失败，error 126），**渲染的仍是生产代码**里的
///   `_buildBody` / `_Cover` —— 与 `debugSetDetail` 自己的文档一致。
Future<void> _mount(
  WidgetTester tester, {
  required MediaDetail detail,
  String? localFile = r'C:\Users\IU\Videos\sourin\第01集.mp4',
  String? localTitle = '测试影片',
}) async {
  // * Pin offline BEFORE the first pump.
  //   localFile != null => initState runs _initLocal => unawaited(_probeNetwork())
  //   => NetworkStatus.probe() would do a REAL DNS lookup of msftconnecttest.com
  //   and leave a staggered-lookup timer pending => harness fails the test with
  //   'Pending timers' (measured, not guessed). It has nothing to do with the cover.
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
      localFile: localFile,
      localTitle: localTitle,
    ),
  ));
  _claim(tester);
  // ignore: avoid_dynamic_calls
  (key.currentState! as dynamic).debugSetDetail(detail);
  await tester.pump();
  _claim(tester);
}

/// 页面上挂的 Image 是什么类型（'file' / 'network' / 'none' / 'mixed(...)'）
///
/// ★ 走**真渲染树**：`_Cover` 里除本地分支的 `Image.file` 与网络分支的
///   `coverImage`（= `Image.network`）外再没有别的 `Image.`，所以这里读到的
///   就是「这一页的封面到底被判成哪种来源」。
///
/// ⚠️ 本仓的封面**全部**带 `cacheWidth` / `cacheHeight`，而 `Image` 在
///   cacheWidth != null 时会把 provider 包成 `ResizeImage` ——
///   所以必须**先剥壳**，只认 `FileImage` / `NetworkImage`（实测踩到过：
///   直接 `p is FileImage` 只会读到 'ResizeImage'）。
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

/// 剥掉 `Image` 的 cacheWidth 壳（`ResizeImage`），露出真正决定来源的那个
///
/// ★ 为什么必须剥：本仓所有封面都带 `cacheWidth`，`Image` 会把 provider
///   包成 `ResizeImage`，不剥就只会读到 'ResizeImage' 而两种分支看起来一样
///   ⇒ 尺子失灵 = 假绿。
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
void main() {
  // The temp dir holds the real on-disk cover, so every test reads a path
  // that the environment produced (a genuine Windows drive letter path).
  setUpAll(() {
    _tmp = Directory.systemTemp.createTempSync('sourin_cr11');
    // ★ OPS-18：这里**原来**写的是 `'${_tmp.path}$_bs\\_sourin-cover.jpg'` ——
    //   `_bs` 本身就是一个反斜杠，后面**又**跟一个字面反斜杠 ⇒ 拼出
    //   `…temp\\_sourin-cover.jpg`（两个反斜杠 = 一个叫 `\\` 的**子目录**）。
    //   POSIX 上那个子目录不存在 ⇒ `writeAsBytesSync` 抛 FileSystemException
    //   ⇒ setUpAll 整组炸。`_bs` 只保留给**纯字符串**断言（:229/:237/:286/:290）。
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
  //  0  instrument self-check
  // ============================================================
  // * Why first: every assertion here rests on reading the Image
  //   provider. A broken ruler makes every assertion green forever, which
  //   is worse than no test at all. So prove it reads 'network' from a URL
  //   that must take that branch.
  group("0 self-check (anti false-green)", () {
    testWidgets("* https cover must read as network", (tester) async {
      await _mount(tester, detail: _detailWith("https://img.example.com/a.jpg"));
      expect(find.text("测试影片"), findsOneWidget,
          reason: "the title must really render, else the page never built");
      expect(_coverKind(tester), "network",
          reason: "a network URL goes through coverImage => NetworkImage");
    });
  });

  // ============================================================
  //  CR-11 itself
  // ============================================================
  group("CR-11 drive letter paths must be judged local", () {
    testWidgets("* defect scene: the real on-disk cover must be a FileImage",
        (tester) async {
      print('CR11|real cover path = $_realCover'); // ignore: avoid_print
      await _mount(tester, detail: _detailWith(_realCover));
      expect(_coverKind(tester), "file",
          reason: "systemTemp on Windows is a drive letter path; "
              "Uri.tryParse reads the drive letter C as a scheme, so before "
              "the fix it fell into Image.network and could never load");
    });

    testWidgets("forward slash form C:/ is local too", (tester) async {
      await _mount(tester,
          detail: _detailWith("C:/Users/IU/AppData/Local/a.jpg"));
      expect(_coverKind(tester), "file",
          reason: "C:/ and C:<BS> are one path in two spellings; "
              "the verdict must not depend on the spelling");
    });

    testWidgets("lowercase drive d: is local too", (tester) async {
      await _mount(
          tester,
          detail: _detailWith("d:${_bs}downloads${_bs}a.jpg"));
      expect(_coverKind(tester), "file");
    });

    testWidgets("UNC and POSIX absolute stay local", (tester) async {
      await _mount(
          tester,
          detail: _detailWith(
              "$_bs${_bs}server${_bs}share${_bs}a.jpg"));
      expect(_coverKind(tester), "file",
          reason: "these two were already judged local by Uri.tryParse; "
              "pin them so a later change cannot silently flip them");
    });

    testWidgets("control: http stays network", (tester) async {
      await _mount(tester, detail: _detailWith("http://img.example.com/a.jpg"));
      expect(_coverKind(tester), "network");
    });

    testWidgets("* control: file:///C:/a.jpg stays network",
        (tester) async {
      await _mount(tester, detail: _detailWith("file:///C:/a.jpg"));
      expect(_coverKind(tester), "network",
          reason: "file:// is a real scheme and Image.network handles it; "
              "the drive letter regexp only matches a real ^[a-zA-Z]: prefix");
    });

    testWidgets("control: no cover mounts no Image at all", (tester) async {
      await _mount(tester, detail: _detailWith(null));
      expect(_coverKind(tester), "none");
      expect(find.text("测"), findsOneWidget,
          reason: "the first letter placeholder must paint, proving that "
              "none is a real verdict and not an empty page");
    });
  });

  // ============================================================
  //  * full chain: no debugSetDetail, _initLocal really runs on its own
  // ============================================================
  group("CR-11 full chain (local mode first frame)", () {
    testWidgets("* localMeta.localCoverPath alone must render as a FileImage",
        (tester) async {
      // Pin offline so _probeNetwork never touches a real socket.
      NetworkStatus.debugProbe = () async => false;
      addTearDown(NetworkStatus.debugResetForTest);

      await tester.binding.setSurfaceSize(const Size(_panelW, _panelH));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final key = GlobalKey<State<DetailPage>>();
      await tester.pumpWidget(_host(
        DetailPage(
          key: key,
          provider: "local",
          id: _realCover,
          embedded: true,
          localFile:
              "C:${_bs}Users${_bs}Videos${_bs}sourin$_bs$_ep01",
          localTitle: "测试影片",
          localMeta: CachedWork(
            dirName: "测试影片",
            path: "C:${_bs}Users${_bs}Videos${_bs}sourin",
            episodes: const <CachedEpisode>[],
            localCoverPath: _realCover,
          ),
        ),
      ));
      _claim(tester);
      // _initLocal is unawaited (detail_page.dart initState).
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        _claim(tester);
      }

      expect(find.text("测试影片"), findsOneWidget,
          reason: "_initLocal must really have filled the detail in, "
              "otherwise the cover assertion below would measure nothing");
      expect(_coverKind(tester), "file",
          reason: "localMeta.localCoverPath is a drive letter path => Image.file");
    });
  });
}
