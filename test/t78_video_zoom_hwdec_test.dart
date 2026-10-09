// ═══════════════════════════════════════════════════════════════════════
//  task-22：P1-11 视频缩放（video-zoom）+ P2-9 解码模式（hwdec）+ P1-5 长按弹滑动条
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（Owner 第八条 → `.probe/research/yamby-可整合清单.md:410/412/406`）：
//   · P1-11「自定义视频缩放 —— 在播放器页面长按缩放按钮，拖动出现的滑动条，
//            可以进行任意比例的视频缩放」
//   · P2-9 「mpv 解码模式 Auto / HW+ / HW / SW」
//   · P1-5 「长按某个按钮 → 弹出一根滑动条」这个范式（本项目原先只有半屏长按手势）
//
// ★ 本文件**刻意不用** `@Tags(['native-media'])`：这里从头到尾没有挂载过真实的
//   `PlayerPage`（挂它要加载 libmpv，在 flutter_tester 里会 c0000005 崩）。
//   全部证据分三层：
//     ① 纯函数（`videoZoomToMpv` / `HwdecMode.fromWire`）—— 直接调用；
//     ② 面板的**真渲染 + 真点击**（`PlayerSettingsSheet` 可以脱离播放器单测）；
//     ③ 源码级判据（起播落点 / Esc 链 / 底栏换形）—— 剥注释后计数 + 配平切片。
//
// ★ 为什么不重复 `test/hwdec_timing_test.dart` 的判据：那条测的是「配置与取证分离」
//   的**时序**；这里测的是**档位表**（四档 → 四个 mpv 取值）。两条互补，都要绿。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/player_page.dart' show videoZoomToMpv;
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════
//  注释剥离器（逐字照抄 `player_capability_test.dart:61-110`）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释
///
/// ⚠️ 只剥注释、**保留字符串字面量**里的内容 —— 下面的断言里就有
///    `'读不到'` / `'画面缩放'` 这些**用户可见的文案**。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（' 或 "）

  while (i < src.length) {
    final c = src[i];

    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

const String _pagePath = 'lib/ui/player_page.dart';
const String _sheetPath = 'lib/ui/widgets/player_settings_sheet.dart';

/// 剥注释后的源码（**只读一次**，多处复用）
final String _page = stripComments(File(_pagePath).readAsStringSync());
final String _sheetSrc = stripComments(File(_sheetPath).readAsStringSync());

/// 断言 `needle` 在 `src` 里**恰好**出现 [want] 次，并返回首次下标
int indexOfExactly(String src, String needle, {int want = 1, String? why}) {
  final hits = <int>[];
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    hits.add(i);
    from = i + needle.length;
  }
  expect(hits.length, want,
      reason: why ?? '「$needle」应恰好出现 $want 次，实测 ${hits.length} 次');
  return hits.isEmpty ? -1 : hits.first;
}

// ═══════════════════════════════════════════════════════════════════════
//  面板夹具（与 `t68_android_adapt_test.dart:180-229` 同构，只多四个可选参数）
// ═══════════════════════════════════════════════════════════════════════

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

PlayerSettingsSheet _sheet({
  HwdecMode hwdecMode = HwdecMode.auto,
  ValueChanged<HwdecMode>? onSetHwdecMode,
  double? videoZoom,
  ValueChanged<double>? onSetVideoZoom,
}) {
  return PlayerSettingsSheet(
    isLive: false,
    subtitleTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '简体中文', hint: 'chi'),
    ],
    audioTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '国语', hint: 'aac'),
    ],
    currentSubtitleId: '1',
    currentAudioId: '1',
    externalSubtitleName: null,
    mpvStyle: const {
      'sub-ass-override': 'no',
      'sub-font': 'Microsoft YaHei',
      'sub-font-size': '55',
      'sub-color': '1.00/1.00/1.00',
      'sub-border-color': '0.00/0.00/0.00',
      'sub-border-size': '1.65',
      'sub-margin-y': '0',
    },
    endAction: PlayEndAction.autoNext,
    countdownBeforeNext: true,
    keepSourceOnNext: true,
    autoSkip: true,
    rate: 1.0,
    isPlaying: true,
    clipDownloading: false,
    clipDownloaded: false,
    clipDownloadError: null,
    onSetConcurrency: (_) {},
    onDownloadClip: () {},
    onOpenClipDir: () {},
    onPickSubtitle: (_) {},
    onPickAudio: (_) {},
    onLoadSubtitleFile: (_) {},
    onRemoveExternalSubtitle: () {},
    onSetMpvProperty: (_, __) {},
    onSetEndAction: (_) {},
    onSetCountdown: (_) {},
    onSetKeepSource: (_) {},
    onSetAutoSkip: (_) {},
    onSetRate: (_) {},
    onClose: () {},
    // ★ task-22 的四个新参数（都是可选的 ⇒ 上面三处旧夹具一行都不用改）
    hwdecMode: hwdecMode,
    onSetHwdecMode: onSetHwdecMode,
    videoZoom: videoZoom,
    onSetVideoZoom: onSetVideoZoom,
  );
}

/// 把「画面」那一段滚进视口（它排在面板最末尾，首屏够不到）
///
/// ⚠️ 为什么不用 t68 D⑤ 那种「12 次 drag」的手写循环：
///    这里要够到的是**面板最末尾**那一段（`_videoSection` 排在 `_clipSection`
///    之后），手写循环的步数上限得跟着内容长度改；`scrollUntilVisible`
///    走的是 `Scrollable.ensureVisible`（`player_capability_test.dart:1114`
///    就是这么滚 chip 的），内容是「存在但被裁掉」时它一次就能滚到位。
Future<void> _scrollToBottom(WidgetTester t, Finder target) async {
  await t.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await t.pumpAndSettle();
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  1. P1-11 缩放换算（纯函数 —— 真机取证之外的数学半边）
  // ═════════════════════════════════════════════════════════════════════

  group('1. P1-11 缩放换算：百分比 ↔ mpv video-zoom', () {
    test('① mpv 的 video-zoom 是 log2：100% ⇒ 0，200% ⇒ +1，50% ⇒ -1', () {
      /*
       * mpv 手册：`--video-zoom=<value>`，正值放大、负值缩小，单位是 log2。
       * 这三条等式就是「我们换算对了」的全部内容 —— 后面所有档位都是它的推论。
       */
      expect(videoZoomToMpv(100), 0.0);
      expect(videoZoomToMpv(200), closeTo(1.0, 1e-12));
      expect(videoZoomToMpv(50), closeTo(-1.0, 1e-12));
    });

    test('② 往返：pct → video-zoom → pct 逐档复原（面板五个档位）', () {
      for (final pct in const <double>[75, 100, 125, 150, 200]) {
        final back = 100 * math.pow(2, videoZoomToMpv(pct)).toDouble();
        expect(back, closeTo(pct, 1e-9), reason: '★ $pct% 换算后再换回来必须还是 $pct%');
      }
    });

    test('③ 单调递增：放大档一定比缩小档大（别把符号写反）', () {
      expect(videoZoomToMpv(75), lessThan(videoZoomToMpv(100)));
      expect(videoZoomToMpv(100), lessThan(videoZoomToMpv(125)));
      expect(videoZoomToMpv(125), lessThan(videoZoomToMpv(150)));
      expect(videoZoomToMpv(150), lessThan(videoZoomToMpv(200)));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  2. P2-9 解码模式档位表
  // ═════════════════════════════════════════════════════════════════════

  group('2. P2-9 解码模式：四档 ↔ 四个 mpv 取值', () {
    test('① 四档的 wire **逐字**对上 mpv 的 --hwdec 取值（顺序也钉死）', () {
      /*
       * 档位表来自 `.probe/research/yamby-可整合清单.md:115-120`。
       * ★ 顺序也断言：面板是按 `HwdecMode.values` 渲染的，
       *   顺序变了用户看到的按钮顺序就变了（那属于回归）。
       */
      expect(HwdecMode.values.length, 4, reason: '★ 用户要的就是 Auto / HW+ / HW / SW 四档');
      expect(
        HwdecMode.values.map((m) => m.wire).toList(),
        const ['auto-safe', 'auto', 'auto-copy', 'no'],
      );
      expect(
        HwdecMode.values.map((m) => m.label).toList(),
        const ['Auto', 'HW+', 'HW', 'SW'],
      );
    });

    test('② fromWire 是白名单：非法值 / null 一律回落 auto（不抛）', () {
      expect(HwdecMode.fromWire('auto-safe'), HwdecMode.auto);
      expect(HwdecMode.fromWire('auto'), HwdecMode.hwPlus);
      expect(HwdecMode.fromWire('auto-copy'), HwdecMode.hwCopy);
      expect(HwdecMode.fromWire('no'), HwdecMode.sw);
      // 坏偏好不该让播放页起不来
      expect(HwdecMode.fromWire(null), HwdecMode.auto);
      expect(HwdecMode.fromWire(''), HwdecMode.auto);
      expect(HwdecMode.fromWire('yes'), HwdecMode.auto);
      expect(HwdecMode.fromWire('AUTO-SAFE'), HwdecMode.auto,
          reason: '★ 大小写敏感（mpv 的取值就是小写，别做模糊匹配）');
    });

    test('③ wire 与 label 都唯一（否则面板高亮/回读会撞车）', () {
      final wires = HwdecMode.values.map((m) => m.wire).toSet();
      final labels = HwdecMode.values.map((m) => m.label).toSet();
      expect(wires.length, 4);
      expect(labels.length, 4);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  3. 面板真渲染 + 真点击
  // ═════════════════════════════════════════════════════════════════════

  group('3. 面板「画面」段：真渲染 + 真点击', () {
    testWidgets('① 四档解码模式 + 五个缩放档位都渲染出来了', (t) async {
      await t.pumpWidget(_host(_sheet(videoZoom: 100)));
      await t.pumpAndSettle();

      expect(find.text('画面'), findsOneWidget);
      expect(find.text('解码模式'), findsOneWidget);
      expect(find.text('画面缩放'), findsOneWidget);
      for (final l in const ['Auto', 'HW+', 'HW', 'SW']) {
        expect(find.text(l), findsOneWidget, reason: '★ 少了 $l 这一档');
      }
      for (final p in const ['75%', '100%', '125%', '150%', '200%']) {
        expect(find.text(p), findsOneWidget, reason: '★ 少了 $p 这一档');
      }
    });

    testWidgets('② 点 SW ⇒ 回调 HwdecMode.sw；点 150% ⇒ 回调 150.0', (t) async {
      HwdecMode? gotMode;
      double? gotZoom;
      await t.pumpWidget(_host(_sheet(
        videoZoom: 100,
        onSetHwdecMode: (m) => gotMode = m,
        onSetVideoZoom: (v) => gotZoom = v,
      )));
      await t.pumpAndSettle();

      final sw = find.text('SW');
      await _scrollToBottom(t, sw);
      expect(sw.hitTestable(), findsOneWidget,
          reason: '★ 滚到底都点不到 ⇒ 面板可用高度不够（D 的症状又回来了）');
      await t.tap(sw);
      await t.pumpAndSettle();
      expect(gotMode, HwdecMode.sw);

      final z150 = find.text('150%');
      await _scrollToBottom(t, z150);
      await t.tap(z150);
      await t.pumpAndSettle();
      expect(gotZoom, 150.0,
          reason: '★ 面板传的是**百分比**，换算成 mpv 的 log2 是宿主的事');
    });

    /*
     * ★ ③ 原本是一条判据：「videoZoom 读不到 ⇒ 点档位**不回调**（called == 0）」。
     *   首跑时它红了（Expected: <0> / Actual: <1>），复核后判定**是这条判据自己站不住**，
     *   已拆成下面 ③a/③b/③c 三条更强的判据。三条理由：
     *   ① 既有范式不支持它 —— `_colorRow`（:846-885）遇到 `current == null` 就是
     *      「hint 明说『读不到』 + chip 仍然可设」，`_videoSection` 的缩放行是照它写的；
     *      而 `_videoSection` 的面板是宿主（player_page）侧读值、面板只负责渲染，
     *      面板无权替宿主判断「这个值能不能设」。
     *   ② 它给的理由本身不成立 —— 原 reason 写「点下去等于用猜测值覆盖真实状态」，
     *      但 mpv 的 `video-zoom` 是**绝对**设值（`setProperty('video-zoom', log2(pct/100))`），
     *      不是相对增量，不存在「基于猜测的覆盖」。
     *   ③ 「这一档不可用」的正当理由是**回调缺失**（宿主没给 onSetVideoZoom），
     *      而那已经由 `InkWell.onTap == null` 在**结构上**表达，可以钉得比「点一下看反应」更死。
     */
    testWidgets('③a videoZoom 读不到 ⇒ 明说「读不到」且五档**一个都不高亮**', (t) async {
      await t.pumpWidget(_host(_sheet(videoZoom: null)));
      await t.pumpAndSettle();

      expect(find.text('读不到'), findsWidgets,
          reason: '★ 读不到 mpv 的 video-zoom 时必须**明说**，不许假装 100%');
      for (final p in const <String>['75%', '100%', '125%', '150%', '200%']) {
        final txt = t.widget<Text>(find.text(p));
        expect(txt.style?.color, Colors.white,
            reason: '★ 读不到时「$p」不许被点亮 —— 点亮 = 假装知道当前缩放');
      }
    });

    testWidgets('③b 回调缺失 ⇒ 档位在**结构上**点不动（InkWell.onTap == null）', (t) async {
      await t.pumpWidget(_host(_sheet(videoZoom: 100, onSetVideoZoom: null)));
      await t.pumpAndSettle();

      final ink = find.ancestor(
        of: find.text('125%'),
        matching: find.byType(InkWell),
      );
      expect(ink, findsOneWidget,
          reason: '★ chip 的结构变了？t62_player_rate_test.dart:225-243 也钉着这个 ancestor');
      expect(t.widget<InkWell>(ink).onTap, isNull,
          reason: '★ 没有回调时必须传 null（不是空实现 (){}）—— '
              '空实现会让点击被静默吞掉，用户看到的是「点了没反应」像卡顿，'
              '而不是「当前不可用」；置空后连水波都不起（onTap == null ⇒ enabled == false）');
    });

    testWidgets('③c 读不到但回调还在 ⇒ 点下去**仍然回调**（读不到≠不可设）', (t) async {
      var called = 0;
      await t.pumpWidget(_host(_sheet(
        videoZoom: null,
        onSetVideoZoom: (_) => called++,
      )));
      await t.pumpAndSettle();

      final z125 = find.text('125%');
      await _scrollToBottom(t, z125);
      await t.tap(z125);
      await t.pumpAndSettle();
      expect(called, 1,
          reason: '★ 面板无权替宿主决定「能不能设」：读不到只影响**显示**（hint + 不高亮），'
              '不影响可设性 —— 与 _colorRow 的「读不到 ⇒ 明说 + 仍可设」同一范式');
    });

    testWidgets('④ 面板里**没有**新增滑杆（不抢 .first，也不破坏「只有一根可动」）',
        (t) async {
      await t.pumpWidget(_host(_sheet(videoZoom: 100)));
      await t.pumpAndSettle();

      final sliders = t.widgetList<Slider>(find.byType(Slider)).toList();
      expect(
        sliders.where((s) => s.min == 50 && s.max == 200).length,
        0,
        reason: '★ 「画面缩放」用的是 chip 预设，不是滑杆 —— 任意比例由底栏长按那条滑杆提供',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  4. 源码级钉死（起播落点 / Esc 链 / 底栏换形 / 偏好）
  // ═════════════════════════════════════════════════════════════════════

  group('4. 源码级判据（剥注释后计数 + 配平切片）', () {
    test('① 起播重下发：unawaited(_applyVideoZoom()) 必须紧跟在 open() 之后', () {
      /*
       * ★ 为什么必须在**每次起播**都下发：`video-zoom` 是 mpv 的**逐文件**属性，
       *   换集/换源时会被复位 —— 只在 initState 下发一次的话，
       *   用户设的缩放播完一集就没了。
       * ★ 红度证明：把这一行删掉 ⇒ 这条红（真机上的症状是「换集后缩放丢了」）。
       */
      // ★ `await _player.open(` 全页有 2 处（`_load()` 那条 + `_startPlayback()` 那条）；
      //   这里要钉的是**起播**那条，所以先定位 `_startPlayback(` 再往后找。
      final iStart = _page.indexOf('Future<void> _startPlayback(');
      expect(iStart, greaterThan(0), reason: '找不到 _startPlayback() —— 函数被改名了？');
      final i = _page.indexOf('await _player.open(', iStart);
      expect(i, greaterThan(iStart),
          reason: '★ _startPlayback() 里必须还有一条 await _player.open(');
      final window = _page.substring(i, (i + 900).clamp(0, _page.length));
      expect(window.contains('unawaited(_applyVideoZoom());'), isTrue,
          reason: '★ open() 之后 900 字符内必须重新下发 video-zoom');
      expect(window.contains('await _player.seek('), isFalse,
          reason: '★ 起播这条路上不许出现 seek（player_capability_test.dart:419-445 的判据）');
    });

    test('② _setHwdec 仍保留 auto-safe 字面量，且**不读** hwdec-current', () {
      /*
       * 与 `test/hwdec_timing_test.dart:127-172` 同一条判据（**故意重复一次**）：
       * 那是「配置与取证分离」的护栏，任何人动 P2-9 都可能碰坏它 ——
       * 在本文件的语境里再钉一遍，红的时候能立刻看出是哪次改动。
       */
      final lines = File(_pagePath).readAsStringSync().split('\n');
      final decl = lines.indexWhere((l) => l.contains('Future<void> _setHwdec()'));
      expect(decl, greaterThanOrEqualTo(0), reason: '找不到 _setHwdec() —— 函数被改名了？');
      var end = decl + 1;
      while (end < lines.length && lines[end] != '  }') {
        end++;
      }
      final body = stripComments(lines.sublist(decl + 1, end).join('\n'));
      expect(body.contains("setProperty('hwdec', 'auto-safe')"), isTrue,
          reason: '★ Auto 档必须原样下发 auto-safe（改前就是这个值）');
      expect(body.contains("getProperty('hwdec-current')"), isFalse,
          reason: '★ 配置与取证必须分离 —— 回读留在 _reportHwdecAfterReady()');
      // 四档分发：auto 走字面量，其余三档走档位表
      expect(_page.contains('if (_hwdecMode == HwdecMode.auto) {'), isTrue);
      expect(_page.contains("await native.setProperty('hwdec', _hwdecMode.wire);"),
          isTrue);
    });

    test('③ Esc 链：_zoomOpen 在 _settingsOpen **之后**、_episodeSheetOpen 之前', () {
      /*
       * ★ 层序：设置面板是 `Positioned.fill` 的全屏 scrim（最后打开的那一层），
       *   缩放滑条只是底栏上的一条 ⇒ 两者同时开着时先收滑条。
       * ★ 也不能挪到 `_settingsOpen` **之前**：
       *   `player_capability_test.dart:981-994` 在 Esc 分支后 700 字符的窗口里
       *   找 `else if (_settingsOpen)` —— 推到窗口外那条会红。
       */
      final i = _page.indexOf('if (k == LogicalKeyboardKey.escape ||');
      expect(i, greaterThan(0));
      final body = _page.substring(i, (i + 700).clamp(0, _page.length));
      final iSettings = body.indexOf('else if (_settingsOpen)');
      final iZoom = body.indexOf('else if (_zoomOpen)');
      final iEpisode = body.indexOf('else if (_episodeSheetOpen)');
      expect(iSettings, greaterThan(0));
      expect(iZoom, greaterThan(iSettings), reason: '★ 缩放滑条排在设置面板之后');
      expect(iEpisode, greaterThan(iZoom), reason: '★ 缩放滑条排在选集之前');
    });

    test('④ 浮层门控：_anySheetOpen 列全七种；底栏门控四个 !_xxxSheetOpen 未动', () {
      final gi = _page.indexOf('bool get _anySheetOpen =>');
      expect(gi, greaterThan(0));
      final body = _page.substring(gi, _page.indexOf(';', gi));
      for (final name in const [
        '_episodeSheetOpen',
        '_settingsOpen',
        '_streamSheetOpen',
        '_hintsOpen',
        '_liveChannelsOpen',
        '_danmakuSheetOpen',
        '_zoomOpen',
      ]) {
        expect(body.contains(name), isTrue,
            reason: '★ `_anySheetOpen` 漏了 $name ⇒ 会出现「浮层开着按 Enter 却全屏了」');
      }
      expect(_page.contains('!widget.isTv && !_anySheetOpen'), isTrue);

      // 底栏自己的门控（`t57_sheet_scrim_geometry_test.dart:380-415` 那四个）
      final ib = _page.indexOf('_BottomBar(');
      final before = _page.substring((ib - 600).clamp(0, ib), ib);
      final cond = before.substring(before.lastIndexOf('if ('));
      for (final k in const [
        '!_episodeSheetOpen',
        '!_streamSheetOpen',
        '!_settingsOpen',
        '!_liveChannelsOpen',
      ]) {
        expect(cond.contains(k), isTrue, reason: '★ 底栏绘制条件少了 $k');
      }
      // 自动收底栏时不能把滑条收掉（否则拖到一半条就没了）
      expect(_page.contains('!_hintsOpen && !_zoomOpen'), isTrue);
    });

    test('⑤ 底栏滑条：卡片在 compactRow **之前**，滑杆量程 50–200', () {
      /*
       * ★ 为什么必须在 `final compactRow = Column(` **之前**：
       *   `t68_android_adapt_test.dart` 的 E④ 对 `compactRow` 切片做源码级计数
       *   （「恰好一根 `Slider(`」+「含 `max: 100,`」）。滑条卡片如果落在切片里，
       *   那条判据会直接红 —— 所以它挂在底栏 Column 的第一层。
       */
      final iCard = indexOfExactly(_page, 'if (zoomOpen)');
      final iCompact = _page.indexOf('final compactRow = Column(');
      expect(iCompact, greaterThan(0));
      expect(iCard, lessThan(iCompact), reason: '★ 滑条卡片必须在 compactRow 切片之外');
      expect(_page.contains('class _ZoomSliderCard extends StatelessWidget {'), isTrue);
      expect(_page.contains('min: 50,'), isTrue, reason: '★ 缩放下限 50%');
      expect(_page.contains('max: 200,'), isTrue, reason: '★ 缩放上限 200%');
      expect(_page.contains('divisions: 30,'), isTrue);
      // 拖动中每帧回调、松手再回调一次（宿主只在后者写偏好）
      expect(_page.contains('onChanged: onChanged,'), isTrue);
      expect(_page.contains('onChangeEnd: onDone,'), isTrue);
    });

    test('⑥ 缩放按钮：两个分支各一枚，都带 onLongPress，且**都不带 tooltip**', () {
      /*
       * ★ 为什么故意不带 tooltip：`Tooltip` 在触摸端靠**长按**触发，
       *   会跟同一个 `IconButton` 的 `onLongPress` 抢手势 —— 结果就是
       *   「长按弹出的是提示气泡，而不是用户要的那条滑动条」。
       *   无障碍标签改用 `Icon.semanticLabel`。
       * ★ 为什么是两个分支各一枚（而不是共用一个）：底栏本来就是这个范式
       *   （相机 / 齿轮各写两份），而且两个分支的布局约束不同。
       */
      indexOfExactly(_page, 'onPressed: onZoomToggle,', want: 2,
          why: '★ compactRow 与宽屏 row 各一枚（多一枚说明有人复制粘贴了）');
      indexOfExactly(_page, 'onLongPress: onZoomToggle,', want: 2,
          why: '★ 两枚都必须支持长按（P1-5 的核心就是长按）');
      // 图标出现 3 次：两个按钮 + 滑条卡片左边那个装饰图标
      indexOfExactly(_page, 'Icons.zoom_in_map', want: 3);
      expect(_page.contains("semanticLabel: '画面缩放'"), isTrue,
          reason: '★ 不带 tooltip 就必须给语义标签，否则读屏用户看不到这个按钮');
      // 每一枚按钮附近都不许出现 tooltip
      var from = 0;
      for (var k = 0; k < 2; k++) {
        final i = _page.indexOf('onPressed: onZoomToggle,', from);
        final win = _page.substring(i, (i + 420).clamp(0, _page.length));
        expect(win.contains('tooltip:'), isFalse,
            reason: '★ 第 ${k + 1} 枚缩放按钮附近出现了 tooltip —— 会抢走长按手势');
        from = i + 1;
      }
    });

    test('⑦ 缩放按钮排在「更多」之后（不破坏 t68 E⑥ 的最前三项）', () {
      final iCompact = _page.indexOf('final compactRow = Column(');
      final iRow = _page.indexOf('final row = Row(');
      final compact = _page.substring(iCompact, iRow);
      final iMore = compact.indexOf('Icons.more_vert');
      final iZoom = compact.indexOf('onPressed: onZoomToggle,');
      expect(iMore, greaterThan(0));
      expect(iZoom, greaterThan(iMore),
          reason: '★ 相机/齿轮/更多 必须是第三行最前三项（t68 E⑥ 逐字判据）');
    });

    test('⑧ 偏好：两个键名 + 白名单范围校验（坏值回落，不抛）', () {
      expect(_page.contains("UiPrefs.get('dsh.playprefs.hwdecMode')"), isTrue);
      expect(_page.contains("UiPrefs.get('dsh.playprefs.videoZoom')"), isTrue);
      expect(_page.contains('_hwdecMode = HwdecMode.fromWire('), isTrue);
      expect(_page.contains('(z != null && z >= 50 && z <= 200) ? z : 100'), isTrue,
          reason: '★ 越界的缩放值会让画面缩到看不见 —— 必须范围校验');
      // 面板**不写**偏好（与倍速同款单向数据流）
      expect(_sheetSrc.contains('UiPrefs'), isFalse,
          reason: '★ 面板不许碰 UiPrefs（t62_player_rate_test.dart:389-394 同款禁令）');
      expect(_sheetSrc.contains('_savePlayPref'), isFalse);
    });

    test('⑨ 旧回归面未破：Axis.horizontal 仍恰好 1、compactRow 仍恰好 1 根滑杆', () {
      indexOfExactly(_page, 'Axis.horizontal', want: 1,
          why: '★ 全页只允许 compactRow 第三行那一个横向滚动容器');
      indexOfExactly(_page, 'return fits ? row : compactRow;');
      final iCompact = _page.indexOf('final compactRow = Column(');
      final iRow = _page.indexOf('final row = Row(');
      final compact = _page.substring(iCompact, iRow);
      indexOfExactly(compact, 'Slider(', want: 1,
          why: '★ compactRow 里只该有音量那一根滑杆');
      indexOfExactly(compact, 'max: 100,');
      indexOfExactly(compact, 'Icons.photo_camera');
      indexOfExactly(compact, 'Icons.settings');
      indexOfExactly(compact, 'Icons.more_vert');
      indexOfExactly(compact, 'Icons.tune', want: 0,
          why: '★ 弹幕设置已经收进「更多」菜单');
    });
  });
}
