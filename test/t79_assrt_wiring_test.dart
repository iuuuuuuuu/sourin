// ═══════════════════════════════════════════════════════════════════════
//  task-31 ⑤：射手字幕（assrt.net）面板接进播放页 —— 接线守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一层守什么（与既有文件的分工）
//
// 射手字幕的三层证据已经各有归属，本文件**只补第五层的「接线」**：
//   · `test/t71_assrt_test.dart`  —— 站点侧的字节事实（魔数 / 错误页 / 真样本）
//   · `lib/core/assrt/*`           —— 搜索 / 下载 / 解包 / 落盘（task-29）
//   · `lib/ui/subtitle/subtitle_panel.dart` —— 面板自己（task-29⑤）
//   · 本文件                       —— **宿主（player_page）有没有把它接对**
//
// 接线错在哪都不会让面板自己变红，所以必须单独钉：
//   ① 宿主必须把 `videoTitle` / `episodeTitle` / `videoUrl` **三个都传真值**
//      —— 面板用它们算 `SubtitleStore.videoKey`（下载目录名），传空 ⇒ 目录算错
//   ② 挂载必须是**一行** `onMount` 转给已有的 `_loadExternalSubtitle`，
//      不许在宿主里再写一套「下载后怎么挂」的逻辑（施工单 §1 原话）
//   ③ 宿主**不许碰 assrt** —— 尤其是署名文案，改一个字就是违约
//   ④ 设置面板的入口文案必须与「加载字幕文件…」**不同**
//      （`player_capability_test.dart:1083` 用的是 `find.text` 精确匹配）
//
// ★ 本文件**不带** `@Tags(['native-media'])`：从头到尾没有挂载过真的
//   `PlayerPage`（挂它要加载 libmpv，flutter_tester 里会 c0000005 崩）。
//   证据分两层：源码级判据（剥注释后计数）+ 面板的真渲染 / 真点击。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/subtitle/subtitle_panel.dart';
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';

// ═══════════════════════════════════════════════════════════════════════
//  注释剥离器（逐字照抄 `player_capability_test.dart:61-110`）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释
///
/// ⚠️ 只剥注释、**保留字符串字面量**里的内容 —— 下面的断言里就有
///    `'在线搜索字幕…'` / `'字幕服务由 assrt.net 提供'` 这些**用户可见的文案**。
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
const String _panelPath = 'lib/ui/subtitle/subtitle_panel.dart';

/// 剥注释后的源码（**只读一次**，多处复用）
///
/// ⚠️ 变量名不能用 `_sheet` —— `test/t78_video_zoom_hwdec_test.dart` 已经因为
///    这个名字撞过一次 `duplicate_definition`（那次撞的是它自己的工厂函数名）。
final String _page = stripComments(File(_pagePath).readAsStringSync());
final String _sheetSrc = stripComments(File(_sheetPath).readAsStringSync());
final String _panelSrc = stripComments(File(_panelPath).readAsStringSync());

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

/// 数 `needle` 在 `src` 里出现几次（**不**断言 —— 用于 `want: 0` 那类判据的报错信息）
int countOf(String src, String needle) {
  var c = 0;
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    c++;
    from = i + needle.length;
  }
  return c;
}

/// 宿主（`player_page.dart`）里**不许出现**的 assrt 痕迹
///
/// 理由：字幕的站点知识全在 `lib/core/assrt/` 与面板里；宿主一旦直接引用
/// 它们，就说明有人把「怎么下字幕」的逻辑又抄了一份到播放页。
const List<String> _hostForbidden = <String>[
  'core/assrt/',
  'AssrtClient',
  'SubtitleStore.',
  '字幕服务由 assrt.net',
  'config:',
];

// ═══════════════════════════════════════════════════════════════════════
//  面板夹具（与 `t78_video_zoom_hwdec_test.dart:110-178` 同构）
// ═══════════════════════════════════════════════════════════════════════

Widget _host(Widget child) {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

/// 播放设置面板夹具 —— 30 个 required 参数逐字照抄 `t78_video_zoom_hwdec_test.dart:119-178`
///
/// ★ 只多一个 `onOpenSubtitleSearch`（task-31 ⑤ 新增的唯一入口）。
PlayerSettingsSheet _settingsSheet({
  HwdecMode hwdecMode = HwdecMode.auto,
  ValueChanged<HwdecMode>? onSetHwdecMode,
  double? videoZoom,
  ValueChanged<double>? onSetVideoZoom,
  VoidCallback? onOpenSubtitleSearch,
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
    // ★ task-31 ⑤ 的新入口（可空 ⇒ 不传时整行不画）
    onOpenSubtitleSearch: onOpenSubtitleSearch,
  );
}

/// 把目标滚进视口（面板比 800x600 的测试面长，末尾几段首屏够不到）
Future<void> _scrollToBottom(WidgetTester t, Finder target) async {
  await t.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await t.pumpAndSettle();
}

/// 面板自己不用它 —— 测试里给 `SubtitlePanel` 的 `onClose` 一个空实现
void _noop() {}

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  //  group 1：源码级 —— 宿主（player_page.dart）把面板接进去了吗
  // ═══════════════════════════════════════════════════════════════════════

  group('① 宿主接线（源码级）', () {
    test('设置面板的入口指向 _openSubtitlePanel', () {
      indexOfExactly(_page, 'onOpenSubtitleSearch: _openSubtitlePanel,');
      expect(_page.contains('void _openSubtitlePanel()'), isTrue,
          reason: '★ 入口指的必须是一个真存在的宿主方法');
    });

    test('挂载块：_subtitlePanelOpen 那一块把七件事全配平了', () {
      /*
       * ★★★ task-104：needle 跟着**挂载形态**走（铁律⑥）
       *
       * ```text
       * 改前：if (_subtitlePanelOpen) SubtitlePanel(...)
       *       ⇒ 判据找 'if (_subtitlePanelOpen)'，取 lastIndexOf
       * 改后：Positioned.fill(child: SheetExitMotion(visible: _subtitlePanelOpen,
       *                                    child: SubtitlePanel(...)))
       *       ⇒ 挂载点里没有 'if (_xOpen)' 字面量了（常挂 + 只翻 visible
       *         才是「关闭也有动画」的前提，见 SheetExitMotion 的类文档）
       * ```
       *
       * ⚠️ 仍然用 `lastIndexOf`：Esc 链里还有一处 `else if (_subtitlePanelOpen)`
       *    （它由 t73 ③ 单独钉顺序），取 last 拿到的仍是**挂载点**。
       * 为什么窗口是 900：挂载点后面紧跟着的是 `SubtitlePanel(` 的实参表，
       *   七个实参 + 缩进实测约 700 字符（task-104 多了一层 SheetExitMotion
       *   与 fill: false），900 仍有余量。
       */
      final i = _page.lastIndexOf('visible: _subtitlePanelOpen,');
      expect(i, greaterThan(0), reason: '★ 找不到字幕面板的挂载点（SheetExitMotion 的 visible:）');
      final win = _page.substring(i, (i + 900).clamp(0, _page.length));
      for (final n in <String>[
        'SubtitlePanel(',
        'onClose:',
        'videoTitle: widget.title',
        "episodeTitle: _currentEpisodeTitle ?? ''",
        "videoUrl: _current?.url ?? ''",
        'onMount:',
        '_loadExternalSubtitle(file.path)',
      ]) {
        expect(win.contains(n), isTrue,
            reason: '★ 挂载块里少了「$n」—— 面板拿不到它就算不出 videoKey / 挂不上字幕');
      }
    });

    test('挂载必须复用既有的加载逻辑，不许在宿主里新写一套', () {
      indexOfExactly(_page, '_loadExternalSubtitle(',
          want: 3,
          why: '★ 三处 = 定义 + 设置面板入口 + 字幕面板挂载；多一处就是有人抄了第二套');
      indexOfExactly(_page, "['sub-add'", want: 2);
      indexOfExactly(_page, "['sub-remove'", want: 2);
      indexOfExactly(_page, "sub-visibility', 'yes'", want: 2);
    });

    test('宿主不许碰 assrt：站点知识全在 core/ 与面板里', () {
      for (final t in _hostForbidden) {
        expect(countOf(_page, t), 0,
            reason: '★ 宿主里出现了「$t」—— 有人把「怎么下字幕」抄进播放页了');
      }
    });

    test('换集重挂的顺序：先 _player.open，再 _applySubtitleStyle', () {
      /*
       * `_applySubtitleStyle()` 里会发 `sub-remove` 把上一条外挂字幕摘掉，
       * 所以它必须排在 `await _player.open(...)` **之后** ——
       * 否则摘的是上一集残留的 id，新的一集反而没被清干净。
       */
      final iOpen = _page.indexOf('await _player.open(');
      final iStyle = _page.indexOf('unawaited(_applySubtitleStyle());');
      expect(iOpen, greaterThan(0));
      expect(iStyle, greaterThan(0));
      expect(iOpen, lessThan(iStyle),
          reason: '★ _applySubtitleStyle 里发 sub-remove ⇒ 必须排在 open 之后');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  group 2：设置面板的真渲染 + 真点击
  // ═══════════════════════════════════════════════════════════════════════

  group('② 设置面板的在线字幕入口', () {
    testWidgets('传了回调 ⇒ 两枚按钮都在；没传 ⇒ 只有旧的那枚', (t) async {
      await t.pumpWidget(_host(_settingsSheet(onOpenSubtitleSearch: () {})));
      await t.pumpAndSettle();
      expect(find.text('在线搜索字幕…'), findsOneWidget);
      expect(find.text('加载字幕文件…'), findsOneWidget);

      await t.pumpWidget(_host(_settingsSheet()));
      await t.pumpAndSettle();
      expect(find.text('在线搜索字幕…'), findsNothing,
          reason: '★ onOpenSubtitleSearch 为 null ⇒ 整行不画（面板可被别的宿主复用）');
      expect(find.text('加载字幕文件…'), findsOneWidget,
          reason: '阳性对照：面板本身画出来了，不是整块没渲染');
    });

    testWidgets('点它 ⇒ 回调真的被调用一次', (t) async {
      var opened = 0;
      await t.pumpWidget(
          _host(_settingsSheet(onOpenSubtitleSearch: () => opened++)));
      await t.pumpAndSettle();
      final btn = find.text('在线搜索字幕…');
      await _scrollToBottom(t, btn);
      expect(btn.hitTestable(), findsOneWidget,
          reason: '★ 没滚到位就点不到 —— tap 会静默不触发回调');
      await t.tap(btn);
      await t.pumpAndSettle();
      expect(opened, 1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  group 3：字幕面板自己的真渲染
  // ═══════════════════════════════════════════════════════════════════════

  group('③ 字幕面板：署名与未连接态', () {
    testWidgets('署名由面板自己画，原文一字不改', (t) async {
      await t.pumpWidget(_host(const SubtitlePanel(
        onClose: _noop,
        videoTitle: '维琴河',
        episodeTitle: 'S01E01',
        videoUrl: 'https://example.invalid/1.m3u8',
      )));
      await t.pumpAndSettle();
      expect(find.textContaining('字幕服务由 assrt.net 提供'), findsOneWidget,
          reason: '★ assrt.net 的 API 条款要求署名 ⇒ 宿主/面板都不许删改');
    });

    testWidgets('onMount 没接上 ⇒ 画「未连接播放页」；接上 ⇒ 不画', (t) async {
      await t.pumpWidget(_host(const SubtitlePanel(
        onClose: _noop,
        videoTitle: '维琴河',
      )));
      await t.pumpAndSettle();
      expect(find.text('未连接播放页'), findsOneWidget);

      await t.pumpWidget(_host(SubtitlePanel(
        onClose: _noop,
        videoTitle: '维琴河',
        onMount: (_) {},
      )));
      await t.pumpAndSettle();
      expect(find.text('未连接播放页'), findsNothing,
          reason: '★ 宿主接了 onMount ⇒ 用户看到的是「能挂到当前播放」而不是警告');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  group 4：面板自身的接线契约（源码级）
  // ═══════════════════════════════════════════════════════════════════════

  group('④ 面板与设置面板的契约', () {
    test('onMount 是可空字段 —— 宿主靠它把路径拿回去', () {
      indexOfExactly(_panelSrc, 'final void Function(SubtitleFileRef file)? onMount;');
    });

    test('onMount 为空时不崩，只把状态写成「已保存到 …」', () {
      indexOfExactly(_panelSrc, 'if (cb == null)');
    });

    test('videoKey 三个字段全传真值（传空 ⇒ 下载目录算错）', () {
      final i = indexOfExactly(_panelSrc, 'SubtitleStore.videoKey(');
      final win = _panelSrc.substring(i, (i + 300).clamp(0, _panelSrc.length));
      expect(win.contains('title: widget.videoTitle'), isTrue);
      expect(win.contains('episodeTitle: widget.episodeTitle'), isTrue);
      expect(win.contains('url: widget.videoUrl'), isTrue);
    });

    test('设置面板：入口可空，且与「加载字幕文件…」是两行', () {
      indexOfExactly(_sheetSrc, 'if (widget.onOpenSubtitleSearch != null)');
      indexOfExactly(_sheetSrc, "'在线字幕'");
      indexOfExactly(_sheetSrc, "'加载字幕文件…'",
          why: '★ 这一枚是既有的外挂字幕入口，⑤ 不许改它的文案/位置');
    });
  });
}
