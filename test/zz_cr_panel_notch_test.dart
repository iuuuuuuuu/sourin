// ═══════════════════════════════════════════════════════════════════════
//  OPS-6 ③「右侧面板崩坏」—— 面板左沿那条 22px 黑带
// ═══════════════════════════════════════════════════════════════════════
//
// # 业主原话（逐字）
//
// > 图三,右侧不知为啥出现崩坏 (本地缓存,我第一次进来还是正常的,再进来就异常了)
//
// # 逐像素实测（业主截图 att_5b143a05 / att_55eb0f31，都是 1444×805）
//
// ```text
// 视频右边缘 = 1010      面板左边缘 = **1033**
// ⇒ x∈[1011,1032] 是一条 **22px 宽**的纯黑竖带
//   px(1020, y) 在**所有** y 上都是 (0,0,0)
//   px(1035, y) 是 (238,240,246) = surface
// ```
// 对照：业主「正常」那一张（att_75b2ea6e）同一位置量到的是
// ```text
// 面板左边缘 = **1011**，黑只到 1010 为止 ⇒ 没有黑带
// ```
//
// # 根因（一行）
//
// lib/ui/media_page.dart 的 detailPanel 里那条
//   Positioned(width: Radii.lg, child: ColoredBox(color: Colors.black))
// 是**故意**铺的黑底（task-68：让面板朝视频那一侧的两个圆角「从视频里挖出来」）。
// 它**只在内容自己不透明时**才被盖住：
//
// ```text
// 右侧 = DetailPage   ⇒ 它自己铺了 ColoredBox(colors.surface)
//                        （lib/ui/detail_page.dart:2513）⇒ 黑被盖住 ⇒ 量到 1011 ✅
// 右侧 = DownloadPanel ⇒ **整块控件没有任何背景绘制**
//                        （lib/ui/widgets/download_panel.dart 全文件只有
//                          :245/:253/:402/:479 的 Text 前景色，没有底色）
//                        ⇒ 黑直接透出来 ⇒ 量到 1033 ❌ ← 业主看到的「崩坏」
// ```
//
// ★ 所以这与「第二次进来」**无关**：只要右侧渲染的是 DownloadPanel，
//   那条 22px 黑带就在。业主的「第一次正常」是因为第一次右侧还是详情区。
//
// # 本文件为什么必须**读像素**（而不是断言 widget 结构）
//
// 「树里有没有一块黑」在本页**永远为真** —— 合并页第 0 个 child 是播放器，
// 它整块就是纯黑（占 x[0..视频宽]）。这正是 t61 文件头记下的教训：
// ```text
// 一个永远为真的判据 = 没有判据
// ```
// ⇒ 只有**渲染出来的像素**能回答「那条黑带有没有露出来」。
//   而业主的截图本身就是像素证据 ⇒ 门禁与证据同一种度量。
//
// ⚠️ 与 t61_panel_radius_test.dart 的分工：
//   · t61 管**圆角形状**（黑底必须盖住视频侧的角、不得侵入标题栏侧的角）
//   · 本文件管**黑带有没有溢出到圆角之外**（业主报的那 22px）
//   两条断言**成对**：修黑带**不能**把圆角填平（那会退回 Owner 投诉过的
//   「直角看起来不协调」）⇒ 所以本文件每条用例都带一个「圆角缺口仍是黑的」阳性对照。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show OffsetLayer, RenderClipRRect;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/download_panel.dart';

// ══════════════════════════════════════════════════════════════════════════
//  libmpv 夹具：跨平台探测 + 缺夹具时**跳过**（不是假红）
// ══════════════════════════════════════════════════════════════════════════
//
// 与 t61_panel_radius_test.dart:134-236 同一手法（本仓既有约定）：
// MediaPage 的第 0 个 child 是 PlayerPage，它 initState 里就 Player()
// ⇒ MediaKit 未就绪会抛 MediaKit.ensureInitialized must be called…，
//   而报错文本是次生的 _elements.contains(element) is not true，会掩盖真因。
//
// ⚠️ **不能**改成 @Tags(['native-media'])：dart_test.yaml 把该标签默认 skip
//    ⇒ 本门禁会从默认套件里**整个消失** —— 那是移除覆盖，不是加守卫。
// ══════════════════════════════════════════════════════════════════════════
List<String> _libmpvCandidates() {
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    final out = <String>[
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
    for (final cfg in const <String>['Release', 'Debug', 'Profile']) {
      final dir = Directory('build/macos/Build/Products/' + cfg);
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is Directory && e.path.endsWith('.app')) {
          out.add(e.path + '/Contents/Frameworks/libmpv-2.dylib');
        }
      }
    }
    return out;
  }
  return <String>[
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
  ];
}

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[PANEL-NOTCH] libmpv 夹具 = ' + _libmpv!);
      return;
    }
  }
  // ignore: avoid_print
  print('[PANEL-NOTCH] libmpv 夹具**缺失** ⇒ 依赖播放器的用例将 markTestSkipped；'
      '候选 = ' + _libmpvCandidates().toString());
}

bool _requireLibmpv() {
  if (_libmpv != null) return true;
  markTestSkipped('libmpv 夹具缺失 ⇒ MediaPage 建不起来，本条无从断言。'
      '手动跑：先 flutter build windows；候选路径 = '
      + _libmpvCandidates().toString());
  return false;
}

// ══════════════════════════════════════════════════════════════════════════
//  夹具：挂一个**真的** MediaPage（1440×900 ⇒ wide ⇒ 右侧有面板）
// ══════════════════════════════════════════════════════════════════════════

/// 面板左沿那条黑底的宽度 —— 必须与 media_page.dart 里的 Radii.lg 同源
///
/// ★ 不写死 22：tokens.dart 改了半径而门禁还认 22，就会**静默**漏判。
double get _bandW => Radii.lg;

Future<void> _pump(WidgetTester t, {Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const MediaPage(
        provider: 'cycani',
        id: '3862',
        title: '无题',
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 50));
}

/// 注入一条**已完成**的下载任务（title 与页面 title 一致 ⇒ 面板认得它）
///
/// ★ 为什么直接写 DownloadQueue.tasks.value 而不走 enqueue()：
///   enqueue 会 unawaited(_pump()) ⇒ 真去建下载器、发真网络请求。
///   在 fake-async 区里那个 future **永不完成** ⇒ 用例 did not complete。
///   而 DownloadPanel 只读 DownloadQueue.tasks 这个 ValueNotifier
///   ⇒ 直接写它就是**充分**的注入。
void _injectDoneTask(String title) {
  DownloadQueue.tasks.value = <DownloadTask>[
    DownloadTask(
      id: 'cycani:3862:ep1',
      title: title,
      episodeTitle: '第01集',
      provider: 'cycani',
      mediaId: '3862',
      episodeId: 'ep1',
      sourceCode: 'kuaikan',
      fileName: '第01集',
      done: 12,
      total: 12,
      state: DownloadState.done,
    ),
  ];
}

/// 收集树里所有指定类型的 RenderObject
List<T> _renders<T extends RenderObject>(WidgetTester t) {
  final out = <T>[];
  void walk(RenderObject ro) {
    if (ro is T) out.add(ro);
    ro.visitChildren(walk);
  }

  walk(t.binding.renderViews.first.child!);
  return out;
}

BorderRadius _radiusOf(RenderClipRRect c) =>
    c.borderRadius.resolve(TextDirection.ltr);

/// 右侧详情面板的矩形（= 那个带圆角的 ClipRRect 的边界）
///
/// ⚠️ 必须按**圆角**过滤：本页还有别的 ClipRRect（卡片、封面）。
///   判据与 t61_panel_radius_test.dart:324-333 一致（上边两角永远圆）。
Rect _panelRect(WidgetTester t) {
  final clips = _renders<RenderClipRRect>(t);
  final panel = clips.where((c) {
    final r = _radiusOf(c);
    return r.topLeft.x > 0 || r.topRight.x > 0;
  }).toList();
  expect(panel, isNotEmpty, reason: '找不到右侧详情面板的 ClipRRect');
  final b = panel.first;
  return b.localToGlobal(Offset.zero) & b.size;
}

/// 整屏像素
class _Pix {
  _Pix(this.bytes, this.w, this.h);

  final Uint8List bytes;
  final int w;
  final int h;

  List<int> at(int x, int y) {
    final i = (y * w + x) * 4;
    return <int>[bytes[i], bytes[i + 1], bytes[i + 2]];
  }

  /// 「纯黑」判据 —— 与像素取证脚本 .probe/ops/pngdec.mjs 同一阈值
  bool isBlack(int x, int y) {
    final p = at(x, y);
    return p[0] < 60 && p[1] < 60 && p[2] < 60;
  }
}

/// 截图读像素
///
/// ★★★ toImage() **必须**在 t.runAsync 里跑 —— widget 测试默认跑在
/// fake-async zone，而 toImage 的 future 由 engine 的**真实**事件循环完成
/// ⇒ 在 fake zone 里永远等不到 ⇒ 用例**静默挂死**（整条命令卡到超时被杀，
///   日志停在用例名那一行）。这条坑记在
///   test/player_panel_dark_and_boundary_test.dart:371-377。
Future<_Pix> _shoot(WidgetTester t) async {
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;
  late Uint8List bytes;
  late int w;
  late int h;
  await t.runAsync(() async {
    final img = await layer.toImage(Offset.zero & size);
    final bd = await img.toByteData();
    w = img.width;
    h = img.height;
    bytes = bd!.buffer.asUint8List();
    img.dispose();
  });
  return _Pix(bytes, w, h);
}

/// 面板左沿那条 22px 黑带里，**圆角之外**的黑色行号（空 = 没有黑带 ✅）
///
/// 取样列 = 面板左边界 + 半条带宽（黑带的**正中心**）。
/// y 范围刻意避开上下两个圆角缺口（各让出 Radii.lg + 4）
/// ⇒ 那里**本来就不该有黑**；有黑 = 黑底溢出到了圆角之外 = 业主报的缺陷。
List<int> _bandBlackRows(_Pix pix, Rect panel) {
  final px = (panel.left + _bandW / 2).round();
  final y0 = (panel.top + _bandW + 4).round();
  final y1 = (panel.bottom - _bandW - 4).round();
  final out = <int>[];
  for (var y = y0; y <= y1; y++) {
    if (pix.isBlack(px, y)) out.add(y);
  }
  return out;
}

/// 模拟「返回上一级」：把整棵 MediaPage 换成空页（dispose 走一遍），
/// 让**下一次** _pump 是货真价实的「第二次进入」。
///
/// ⚠️ 必须放在 t.runAsync 里并给一段**真**延时：MediaPage / PlayerPage 的
///    dispose 会去停播放器、取消订阅，那些 future 由 engine 的**真实**事件循环
///    完成；在 fake-async 区里等不到 ⇒ 上一轮的 State 不会真正释放，
///    「第二次进入」就退化成假动作（与业主的复现路径不符）。
Future<void> _popToBlank(WidgetTester t) async {
  await t.runAsync(() async {
    await t.pumpWidget(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await t.pump();
  });
}

/// 把积压的框架异常收走（诊断用：返回值只打印，**不做**断言）
///
/// 退出播放页时可能抛与像素无关的次生异常（缺插件 / 播放器拆除）；
/// 让它们把「黑带」这条断言染红，等于门禁在报别的东西。
List<String> _drainExceptions(WidgetTester t) {
  final out = <String>[];
  Object? e;
  while ((e = t.takeException()) != null) {
    out.add('$e');
  }
  return out;
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  setUp(() => RemoteBridge.instance.stop());

  tearDown(DownloadQueue.debugReset);

  group('★ OPS-6 ③ 面板左沿不得露出那条 22px 黑带', () {
    testWidgets('★★★ 右侧 = DownloadPanel（有下载记录）⇒ 圆角之外不得有黑',
        (t) async {
      if (!_requireLibmpv()) return;

      _injectDoneTask('无题');
      await _pump(t);

      // ── 夹具前置：右侧**确实**渲染的是 DownloadPanel ──
      // ★ 这是前置条件，不是被测断言：夹具不成立时后面的像素断言没有意义。
      expect(
        find.byType(DownloadPanel),
        findsOneWidget,
        reason: '夹具前置：注入下载记录后右侧应当渲染 DownloadPanel。'
            '不成立 ⇒ 本条测的不是 OPS-6 那个场景。',
      );

      final panel = _panelRect(t);
      final pix = await _shoot(t);
      final px = (panel.left + _bandW / 2).round();

      final blacks = _bandBlackRows(pix, panel);
      final tail = blacks.isEmpty
          ? ''
          : '  前几行 = ' + blacks.take(5).toList().toString();
      // ignore: avoid_print
      print('[PANEL-NOTCH] 面板 = ' + panel.toString()
          + '  band = ' + _bandW.toString()
          + '  取样列 x = ' + px.toString()
          + '  黑行数 = ' + blacks.length.toString() + tail);

      expect(
        blacks,
        isEmpty,
        reason: '★★★ 业主 ③「右侧不知为啥出现崩坏」的**根因读数**：\n'
            '面板左沿那条 22px 黑底（media_page.dart 的 '
            'Positioned(width: Radii.lg, child: ColoredBox(Colors.black))，'
            'task-68 为圆角铺的）**溢出到了圆角之外**。\n'
            '它在右侧渲染 DetailPage 时被盖住（detail_page.dart:2513 '
            'ColoredBox(color: colors.surface)），\n'
            '但 DownloadPanel **自己不铺任何底色** ⇒ 黑直接透出来。\n'
            '业主截图 att_5b143a05 实测：视频右边缘 1010、面板左边缘 1033 '
            '⇒ x∈[1011,1032] 全黑。\n'
            '实测黑行 = ' + blacks.take(12).toList().toString()
            + (blacks.length > 12
                ? ' …共 ' + blacks.length.toString() + ' 行'
                : ''),
      );

      // ── 阳性对照：圆角缺口处**必须仍是黑的** ──
      // 否则「修黑带」可能变成「把黑底整个删掉 / 填平圆角」
      // ⇒ 退回 Owner 投诉过的「直角看起来不协调」（t61 守的就是这条）。
      final cy = (panel.top + 1).round();
      // ignore: avoid_print
      print('[PANEL-NOTCH] 阳性对照：圆角缺口 px(' + px.toString() + ', '
          + cy.toString() + ') = ' + pix.at(px, cy).toString());
      expect(
        pix.isBlack(px, cy),
        isTrue,
        reason: '★★ 阳性对照必须成立：面板左上角的圆角缺口处**应当**是黑的 ——\n'
            '那是 task-68 故意铺的黑底，圆角靠它才看得见。\n'
            '这里若变成 surface，说明修复把圆角一起填平了 ⇒ '
            'Owner 会重新投诉「直角看起来不协调」。\n'
            '实测像素 = ' + pix.at(px, cy).toString(),
      );
    });

    testWidgets('★★ 右侧 = DetailPage（无下载记录）⇒ 同样不得有黑（对照支）',
        (t) async {
      if (!_requireLibmpv()) return;

      // ★ 不注入任何任务 ⇒ mine 与 onDisk 都空 ⇒ 右侧 = 详情区
      await _pump(t);

      expect(
        find.byType(DownloadPanel),
        findsNothing,
        reason: '对照支前置：没有下载记录时右侧应当是详情区，不是 DownloadPanel',
      );

      final panel = _panelRect(t);
      final pix = await _shoot(t);
      final px = (panel.left + _bandW / 2).round();

      final blacks = _bandBlackRows(pix, panel);
      // ignore: avoid_print
      print('[PANEL-NOTCH] 对照支：面板 = ' + panel.toString()
          + '  取样列 x = ' + px.toString()
          + '  黑行数 = ' + blacks.length.toString());

      expect(
        blacks,
        isEmpty,
        reason: '★ 右侧是 DetailPage 时，面板左沿的 22px 黑底**必须**被 '
            'DetailPage 自己的 ColoredBox(color: colors.surface) 盖住。\n'
            '这里变红 ⇒ 详情支也退化了（业主截图 att_75b2ea6e 量到的 '
            '面板左边缘 = 1011，没有黑带）。',
      );
    });

    testWidgets('★★★ A③ 第二次进入（带下载记录）⇒ 圆角之外仍然不得有黑',
        (t) async {
      if (!_requireLibmpv()) return;

      // ══════════════════════════════════════════════════════════════════
      //  ★★★ 业主原话是「本地缓存，我**第一次进来还是正常的，再进来就异常了**」。
      //  上面两条覆盖的是「右侧**是谁**」（DownloadPanel / DetailPage），
      //  都只进入**一次**；本条补的是**同一个页面第二次进入**这个维度 ——
      //  两次进入之间 DownloadQueue 里**始终有**下载记录。
      //
      //  ⇒ 本条若变红，说明「第二次进入」这条路径上黑带真的会露出来
      //    （跨次残留：上一次留下的 State / 全局单例 / 静态缓存）。
      // ══════════════════════════════════════════════════════════════════

      // ── 第一次进入：注入下载记录 ⇒ 右侧 = DownloadPanel ──
      _injectDoneTask('无题');
      await _pump(t);

      expect(
        find.byType(DownloadPanel),
        findsOneWidget,
        reason: '★ 第一次进入的前置：注入下载记录后右侧应当渲染 DownloadPanel',
      );

      final panel1 = _panelRect(t);
      final pix1 = await _shoot(t);
      final blacks1 = _bandBlackRows(pix1, panel1);
      // ignore: avoid_print
      print('[PANEL-NOTCH] A③ 第一次进入：面板 = ' + panel1.toString()
          + '  黑行数 = ' + blacks1.length.toString());
      expect(
        blacks1,
        isEmpty,
        reason: '★★ A③ 第一次进入（右侧 = DownloadPanel）就不得有黑 ——\n'
            '这是「第一次正常」那一半；它若红了，本条的后半段无从对比。\n'
            '实测黑行 = ' + blacks1.take(12).toList().toString(),
      );

      // ── 返回上一级：整棵 MediaPage 被换掉，dispose 走一遍 ──
      await _popToBlank(t);
      final exitErrors = _drainExceptions(t);
      // ignore: avoid_print
      print('[PANEL-NOTCH] A③ 退出时积压的框架异常 = '
          + exitErrors.length.toString());
      for (final e in exitErrors.take(3)) {
        // ignore: avoid_print
        print('[PANEL-NOTCH] A③   ✗ ' + e.split('\n').take(3).join(' ⏎ '));
      }

      // ── 第二次进入：DownloadQueue 里**仍然**有下载记录 ──
      expect(
        DownloadQueue.tasks.value,
        isNotEmpty,
        reason: '★★ 前提：两次进入之间下载记录必须还在 —— 这正是业主'
            '「本地缓存，再进来」的场景。若这里空了，第二条测的就变成了'
            '「无下载记录」，与业主场景不符。',
      );

      await _pump(t);

      expect(
        find.byType(DownloadPanel),
        findsOneWidget,
        reason: '★ 第二次进入的前置：下载记录仍在 ⇒ 右侧仍应渲染 DownloadPanel。'
            '不成立 ⇒ 本次采样取到的不是下载面板那一路。',
      );

      final panel2 = _panelRect(t);
      final pix2 = await _shoot(t);
      final px2 = (panel2.left + _bandW / 2).round();
      final blacks2 = _bandBlackRows(pix2, panel2);
      final tail2 =
          blacks2.isEmpty ? '' : '  前几行 = ' + blacks2.take(5).toList().toString();
      // ignore: avoid_print
      print('[PANEL-NOTCH] A③ 第二次进入：面板 = ' + panel2.toString()
          + '  band = ' + _bandW.toString()
          + '  取样列 x = ' + px2.toString()
          + '  黑行数 = ' + blacks2.length.toString() + tail2);

      expect(
        blacks2,
        isEmpty,
        reason: '★★★ A③「第二次进入」的硬门禁：业主原话「本地缓存，我第一次进来'
            '还是正常的，**再进来**就异常了」。\n'
            '两次进入之间没有任何清理动作（DownloadQueue 里始终有下载记录）⇒\n'
            '第二次进入后，面板左沿那条 22px 黑底（media_page.dart 的 '
            'Positioned(width: Radii.lg, child: ColoredBox(Colors.black))）'
            '**仍然不得**溢出到圆角之外。\n'
            '它被 lib/ui/media_page.dart:1736 的 '
            'ColoredBox(color: surface, child: detailOrDownloads) 盖住 —— '
            '该层是「内容永远不透明」的保证，与第几次进入无关。\n'
            '实测黑行 = ' + blacks2.take(12).toList().toString()
            + (blacks2.length > 12
                ? ' …共 ' + blacks2.length.toString() + ' 行'
                : ''),
      );

      // ── 阳性对照：圆角缺口处**必须仍是黑的** ──
      // 否则「第二次进入没有黑带」可能只是因为黑底整个不见了 / 圆角被填平
      // ⇒ 退回 Owner 投诉过的「直角看起来不协调」（t61 守的就是这条）。
      final cy2 = (panel2.top + 1).round();
      // ignore: avoid_print
      print('[PANEL-NOTCH] A③ 阳性对照：圆角缺口 px(' + px2.toString() + ', '
          + cy2.toString() + ') = ' + pix2.at(px2, cy2).toString());
      expect(
        pix2.isBlack(px2, cy2),
        isTrue,
        reason: '★★ A③ 阳性对照必须成立：第二次进入后，面板左上角的圆角缺口处'
            '**应当**是黑的（task-68 故意铺的黑底）。\n'
            '这里若变成 surface，说明「黑带消失」是因为黑底被删掉 / 圆角被填平，'
            '而不是因为内容盖住了它 ⇒ Owner 会重新投诉「直角看起来不协调」。\n'
            '实测像素 = ' + pix2.at(px2, cy2).toString(),
      );
    });
  });
}
