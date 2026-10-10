// ═══════════════════════════════════════════════════════════════════════
//  OPS-6 回归探针：连续**两次**进入同一部本地影片，右侧面板布局必须逐项一致
// ═══════════════════════════════════════════════════════════════════════
//
// 业主原话（第 1009 批 ③，逐字）：
// > 图三,右侧不知为啥出现崩坏 (本地缓存,我第一次进来还是正常的,再进来就异常了)
//
// # 这条用例在证明什么
// ```text
// 「第二次才崩」= 一定有**跨次残留**（上一次留下的 State / 全局单例 /
// 静态缓存 / 挂了不止一次的 listener / 第一次写完没还原的共享读数）。
// ⇒ 判据**不能**跟硬编码常量比（那是假门禁：常量对不上只说明"设计变了"，
//   不说明"第二次崩了"），必须**同一套度量连跑两次、两次逐项相等**。
// ```
//
// # 复现路径（与业主一致）
// ```text
// 本地已缓存的影片 → 点进去（第一次）→ 返回上一级 → 再点进去（第二次）
// ```
// 本文件用「挂载 MediaPage → 换成空页（= 返回上一级）→ 再挂载**全新**
// MediaPage」模拟 shell 每次 push 新路由（见 lib/shell.dart:_openCachedWork）。
//
// ⚠️ 数据一律造在系统临时目录（clip_download 的 dataDir 也指向它），
//    **绝不碰** %APPDATA%\app.sourin.player 与 Owner 真实下载目录。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/player_page.dart';

import 'support/ui_shot.dart';

Directory _sandbox(String name) {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}$name';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

Widget _appWith(Widget home) => mui.MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: home,
    );

Widget _mediaPage(CachedPlayRequest req, CachedWork work) => MediaPage(
      provider: req.provider,
      id: req.mediaId,
      title: req.title,
      episodeId: req.episode.fileName,
      localPath: req.episodeAbsolutePath,
      localMeta: work,
    );

String _rect(Rect? r) => r == null
    ? 'null'
    : '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
        '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

/// 一次「进入播放页」的全部读数（在稳定帧之后取）
class _Reading {
  _Reading({
    required this.tag,
    required this.errors,
    required this.detailRect,
    required this.playerRect,
    required this.scrollRects,
    required this.texts,
    required this.renderDump,
  });

  final String tag;

  /// 这一次进入期间被框架抛出的异常（溢出 / 断言 / 布局错误）
  final List<String> errors;

  final Rect? detailRect;
  final Rect? playerRect;
  final List<Rect> scrollRects;

  /// 屏幕上所有 Text（含 offstage），按树序
  final List<String> texts;

  /// 右侧详情区子树的渲染盒 dump（诊断用）
  final List<String> renderDump;

  /// 判据指纹：两次必须逐字符相等
  Map<String, String> fingerprint() => <String, String>{
        '右侧面板(DetailPage) 矩形': _rect(detailRect),
        '播放器(PlayerPage) 矩形': _rect(playerRect),
        '可滚动区个数': '${scrollRects.length}',
        '可滚动区[0] 矩形':
            scrollRects.isEmpty ? 'null' : _rect(scrollRects.first),
        '全部文本': texts.join(' | '),
        '右侧渲染盒': renderDump.join(' / '),
      };
}

List<String> _dumpRenderTree(RenderObject root,
    {int maxDepth = 4, int cap = 90}) {
  final out = <String>[];
  void walk(RenderObject ro, int depth) {
    if (out.length >= cap || depth > maxDepth) return;
    var geo = '';
    if (ro is RenderBox && ro.hasSize) {
      final o = ro.localToGlobal(Offset.zero);
      geo = '${o.dx.toStringAsFixed(0)},${o.dy.toStringAsFixed(0)} '
          '${ro.size.width.toStringAsFixed(0)}x${ro.size.height.toStringAsFixed(0)}';
    }
    out.add('${'·' * depth}${ro.runtimeType.toString()} $geo');
    ro.visitChildren((c) => walk(c, depth + 1));
  }

  walk(root, 0);
  return out;
}

// ══════════════════════════════════════════════════════════════════════════
//  libmpv 夹具：跨平台探测 + 缺夹具时**跳过**（不是假红、更不是假绿）
// ══════════════════════════════════════════════════════════════════════════
//
// 与 t61_panel_radius_test.dart:167-242 / t72_jank_test.dart:186-219 /
// zz_cr_panel_notch_test.dart:83-144 同一手法（本仓既有约定）：
// MediaPage 的第 0 个 child 是 PlayerPage，它 initState 里就 Player()
// ⇒ MediaKit 未就绪会抛 MediaKit.ensureInitialized must be called…，
//   而播放器子树会被 ErrorWidget 整个顶替 ⇒ 下面的六项指纹会「自己等于自己」。
//
// ★ 为什么缺夹具是 **skip** 而不是 fail：`build/` 被 .gitignore 忽略、从不入库，
//   而 CI 的 flutter test 排在 flutter build windows|macos **之前** ⇒ 没跑过构建的
//   机器上夹具**必然缺席**。那是环境前提，不是本文件的缺陷。
// ⚠️ **不能**改成 @Tags(['native-media'])：dart_test.yaml 把该标签默认 skip
//   ⇒ 本门禁会从默认套件里**整个消失** —— 那是移除覆盖，不是加守卫。
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
      // pod 的 vendored framework（pod install 之后）
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
    // flutter build macos 之后 libmpv 就在 app 包里
    // （★ app 名不一定是 sourin_spike —— 发布版是中文「源影」⇒ 扫目录）
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
/// ⚠️ 探不到时这里**绝不 fail** —— 守卫下沉到 `_requireLibmpv()`，
///   由依赖播放器的用例自己调（本文件 1 条用例，全都依赖播放器）。
void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[CR-DOUBLE-ENTER] libmpv 夹具 = $_libmpv');
      return;
    }
  }
  // ignore: avoid_print
  print('[CR-DOUBLE-ENTER] libmpv 夹具**缺失** ⇒ 依赖播放器的用例将 markTestSkipped；'
      '候选 = ${_libmpvCandidates()}');
}

/// 依赖播放器的用例开头调用：`if (!_requireLibmpv()) return;`
///
/// 返回 `true` = 夹具就绪可继续；`false` = **已标记跳过，调用方必须 return**
/// （`markTestSkipped` 只打标记，**不会**中断当前函数 —— 本地实测：标记之后
/// 的代码照常执行，所以必须紧跟 `return`）。
bool _requireLibmpv() {
  if (_libmpv != null) return true;
  if (Platform.environment['SOURIN_REQUIRE_LIBMPV'] == '1') {
    fail(
      'libmpv 夹具缺失：${File(_libmpvCandidates().first).absolute.path} 不存在'
      '（被 SOURIN_REQUIRE_LIBMPV=1 要求为硬失败）',
    );
  }
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来，本条无从断言。'
      '手动跑：先 `flutter build windows`（或 macOS 上 `flutter build macos`）'
      '；候选路径 = ${_libmpvCandidates()}');
  return false;
}

void main() {
  late Directory root;
  late Directory workDir;
  late CachedWork work;
  late CachedPlayRequest req;

  setUpAll(loadRealFonts);
  setUpAll(_prepareLibmpvFixture);

  setUp(() {
    // ⚠️ MediaKit 的初始化已上移到 `setUpAll(_prepareLibmpvFixture)`：
    //    那里用**跨平台**候选表探测。原来这里只认
    //    `build/windows/x64/libmpv/libmpv-2.dll` 一条路径 ⇒ macOS 上即使
    //    崩坏引擎真的在也永远探不到。MediaKit.ensureInitialized
    //    幂等（_initialized 为真就直接 return），此处不再重复。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async =>
          call.method == 'Create' ? 'cr-panel-fake-texture' : null,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
    });

    UiPrefs.debugResetForTest();
    root = _sandbox('sourin_cr_panel');
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    ClipDownloader.debugSetDataDir(root.path);
    CachePage.debugScanRootOverride = root.path;

    workDir = Directory('${root.path}${Platform.pathSeparator}无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= 3; i++) {
      File('${workDir.path}${Platform.pathSeparator}第0$i集 第0$i集.mp4')
          .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x42));
    }
    // ★ 扫盘是真 IO ⇒ 用同步 listSync 造同一份 CachedWork（绝不在
    //   fake-async 区里 await 真 IO：永不完成 ⇒ 用例 did not complete）
    work = CachedWork(
      dirName: '无职转生 第三季',
      path: workDir.path,
      title: '无职转生 第三季',
      episodes: <CachedEpisode>[
        for (final f in workDir.listSync().whereType<File>())
          CachedEpisode(
            fileName: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            isComplete: true,
          ),
      ],
    );
    req = buildLocalPlayRequest(work)!;

    // ⚠️ 不能劫持 debugPrint：flutter_test 在用例结束时会跑
    //    debugAssertAllFoundationVarsUnset，发现 debugPrint 被改就报
    //    「The value of a foundation debug variable was changed by the test」。
    //    ⇒ 诊断输出直接走 debugPrint（flutter test 会打到控制台）。
  });

  tearDown(() {
    CachePage.debugScanRootOverride = null;
    ClipDownloader.debugSetDataDir(null);
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_cr_panel');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  /// 稳定帧：跑满 rounds 次真延时 + pump，期间把异常全部收走
  Future<List<String>> pumpStable(WidgetTester t, {int rounds = 40}) async {
    final errors = <String>[];
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
      Object? e;
      while ((e = t.takeException()) != null) {
        errors.add('$e');
      }
    }
    return errors;
  }

  _Reading read(WidgetTester t, String tag, List<String> errs) {
    final detail = find.byType(DetailPage);
    final player = find.byType(PlayerPage);
    final scrolls = find.byType(SingleChildScrollView);
    final scrollRects = <Rect>[
      for (var i = 0; i < scrolls.evaluate().length; i++)
        t.getRect(scrolls.at(i)),
    ];
    final texts = t
        .widgetList<mui.Text>(find.byType(mui.Text, skipOffstage: false))
        .map((w) => w.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final dump = detail.evaluate().isEmpty
        ? const <String>[]
        : _dumpRenderTree(
            t.renderObject<RenderObject>(detail.first),
          );
    return _Reading(
      tag: tag,
      errors: errs,
      detailRect: detail.evaluate().isEmpty ? null : t.getRect(detail.first),
      playerRect: player.evaluate().isEmpty ? null : t.getRect(player.first),
      scrollRects: scrollRects,
      texts: texts,
      renderDump: dump,
    );
  }

  Future<_Reading> enter(WidgetTester t, String tag) async {
    late List<String> errs;
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(_mediaPage(req, work)));
      errs = await pumpStable(t);
    });
    final r = read(t, tag, errs);
    debugPrint('═══ [$tag] 读数 ═══');
    for (final e in r.fingerprint().entries) {
      debugPrint('[$tag] ${e.key} = ${e.value}');
    }
    debugPrint('[$tag] 异常 ${r.errors.length} 条');
    for (final e in r.errors.take(6)) {
      debugPrint('[$tag] ✗ ${e.split('\n').take(4).join(' ⏎ ')}');
    }
    return r;
  }

  testWidgets('两次进入同一部本地影片：右侧面板布局读数必须逐项一致', (t) async {
    if (!_requireLibmpv()) return;
    await setShotViewport(t, const Size(1440, 900));

    final r1 = await enter(t, '第一次');
    await saveViewShot(t, 'cr_panel_enter1');

    // ★ 前提自检：第一次必须是"正常"的那一次，否则整条用例无意义
    expect(r1.detailRect, isNotNull, reason: '★ 前提：第一次进来右侧必须有详情区');
    expect(r1.texts.join('\n').contains('已下载'), isTrue,
        reason: '★ 前提：第一次进来右侧必须有「已下载」那一段');

    // ── 返回上一级（模拟 pop：整棵 MediaPage 被换掉、dispose 走一遍）──
    await t.runAsync(() async {
      await t.pumpWidget(_appWith(const mui.SizedBox.shrink()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await t.pump();
    });

    final r2 = await enter(t, '第二次');
    await saveViewShot(t, 'cr_panel_enter2');

    final f1 = r1.fingerprint();
    final f2 = r2.fingerprint();
    final diffs = <String>[];
    for (final k in f1.keys) {
      if (f2[k] != f1[k]) {
        diffs.add('【$k】\n  第一次: ${f1[k]}\n  第二次: ${f2[k]}');
      }
    }
    for (final d in diffs) {
      debugPrint('★★★ 两次不一致 $d');
    }
    debugPrint('★★★ 不一致项数 = ${diffs.length} / ${f1.length}');
    expect(diffs, isEmpty,
        reason: '★★★ 第二次进入的布局读数必须与第一次完全一致（同一套度量两次对比）');

    // ★★★ 异常面（T14 审计：本文件曾是「唯一的真·假绿」）★★★
    //
    // 上面六项指纹全是「布局读数」——播放器子树一旦被 ErrorWidget 顶替，
    // 六项会**自己等于自己**（两次都崩成同一形状）⇒ 不读异常面就会放行。
    // 本地实测（CI 形状：三个崩坏引擎都缺席）：本文件曾打出
    //   `00:05 +1: All tests passed!`（exit 0）
    // 而日志里同时有 `_Exception: MediaKit.ensureInitialized must be called…`
    // （media_page.dart:1765 ← player_page.dart:2187）—— 那次「绿」是假的。
    // ⇒ 进入期抛出的异常必须为 0；非 0 时把原文打进失败理由，别让人再猜。
    final allErrors = <String>[...r1.errors, ...r2.errors];
    for (final e in allErrors.take(6)) {
      debugPrint('★★★ 进入期异常 ✗ ${e.split('\n').take(4).join(' ⏎ ')}');
    }
    debugPrint('★★★ 进入期异常条数 = ${allErrors.length}');
    final firstErr = allErrors.isEmpty
        ? '无'
        : allErrors.first.split('\n').take(4).join(' ⏎ ');
    expect(
      allErrors,
      isEmpty,
      reason: '★★★ 进入播放页期间框架不得抛出任何异常'
          '（第一次 ${r1.errors.length} 条 / 第二次 ${r2.errors.length} 条）。'
          '播放器子树被 ErrorWidget 顶替时，上面六项布局指纹会「自己等于自己」'
          '⇒ 只有这一条能把它抓住。首条异常 = $firstErr',
    );
  });
}
