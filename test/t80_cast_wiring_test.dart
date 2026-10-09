// ═══════════════════════════════════════════════════════════════════════
//  task-32 ②：投屏（DLNA）的**接线**（宿主侧 = player_page.dart）
// ═══════════════════════════════════════════════════════════════════════
//
// 控件本体（`CastButton` 的三态 tooltip / 失败不装成投屏中）由 tvbox-sub 的
// `test/t69_dlna_test.dart`（28 用例）与 `lib/ui/cast/cast_button.dart` 自己守。
// **这个文件只守「接进去了没有」**：
//
// ```text
// ① 宿主把哪条流交给控件（必须是 `_current`，不是新字段、不是空串兜底）
// ② 没流时**不画**按钮（门控 `castUrl.isNotEmpty`）—— 卡面「没流不给点」
// ③ 按钮在底栏两支里的位置（窄屏必须排在「更多」之后 ⇒ 不破坏 t68 E⑥）
// ④ 铁律：宿主里**零**投屏状态机痕迹（不做假状态、不包乐观显示）
// ⑤ 控件自身的两态真渲染（空 url / 有流），全程零网络
// ```
//
// ★ 为什么不挂真 `PlayerPage`：它的 `initState` 会 `Player(` +
//   `VideoController(_player)`，`flutter_tester` 加载 `libmpv-2.dll` 时直接崩
//   （实测 `test/t63_shot_ui_test.dart` 整文件 `did not complete`）。
//   ⇒ 宿主侧判据只能是**源码级**的；真机几何由 uiautomator dump 验收。
//
// ★ 本文件**不发一个网络包、不占一个端口**：
//   · 源码级判据只读文件；
//   · `CastButton.initState` 只做 `_m.onLog ??= widget.onLog; _session = _m.session;`，
//     `MediaProxy` 的 `HttpServer.bind` 在 `start()` 里（惰性）；
//   · ★ **绝不 tap** 那枚有 url 的按钮 —— 那会走 `showCastDeviceSheet` 真发 SSDP。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/cast/cast_button.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ══════════════════════════════════════════════════════════════════════
//  源码级判据的底座（`stripComments` 逐字照抄 `test/player_capability_test.dart:61-110`）
// ══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）。
///
/// ⚠️ 必须剥：`lib/ui/player_page.dart` 的注释里**正写着**
///    `if (onCast != null && castUrl.isNotEmpty)` 这类片段 —— 不剥就会
///    把「注释里提了一句」当成「接线真的改了」（本仓踩过 5 次）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
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

/// 剥注释后的宿主源码（**只读一次**）
final String _page = stripComments(File(_pagePath).readAsStringSync());

/// 断言 `needle` 在 `src` 里**恰好**出现 [want] 次，并返回首次下标。
///
/// ⚠️ 不用 `contains` 而用**计数**：`contains` 在「改错了地方」时照样绿
///    （比如把参数加到了另一支，总数仍是 1）。
int indexOfExactly(String src, String needle, {int want = 1, String? why}) {
  final hits = <int>[];
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    hits.add(i);
    from = i + needle.length;
  }
  expect(hits.length, want, reason: why ?? '「$needle」应恰好出现 $want 次，实测 ${hits.length} 次');
  return hits.isEmpty ? -1 : hits.first;
}

/// 数 `needle` 在 `src` 里出现几次（**不**断言 —— 只用于 `want: 0` 那类判据的报错信息）
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

/// 取 `start` 之后第一次出现 `open` 到**配平**的 `close` 之间的文本
///
/// 逐字照抄 `test/t68_android_adapt_test.dart:145-162` —— 只按固定字数切片会在
/// 以后有人往里面加注释时**静默切错**（本项目踩过）。
String sliceBalanced(String src, int start, String open, String close) {
  final begin = src.indexOf(open, start);
  expect(begin, greaterThanOrEqualTo(0), reason: '找不到「$open」');
  var depth = 0;
  for (var i = begin; i < src.length; i++) {
    if (src.startsWith(open, i)) {
      depth++;
      i += open.length - 1;
      continue;
    }
    if (src.startsWith(close, i)) {
      depth--;
      if (depth == 0) return src.substring(begin, i + close.length);
      i += close.length - 1;
    }
  }
  fail('括号没配平：从 $begin 起');
}

// ══════════════════════════════════════════════════════════════════════
//  底栏两支的坐标（**与 t68 E⑥ 同一套切片**，见 `t68_android_adapt_test.dart:605-614`）
// ══════════════════════════════════════════════════════════════════════

/// 宽屏那一支（`final row = Row(` → `return fits ? row : compactRow;`）
String _wideSlice() {
  final iRow = indexOfExactly(_page, 'final row = Row(');
  final iEnd = indexOfExactly(_page, 'return fits ? row : compactRow;');
  expect(iEnd, greaterThan(iRow));
  return _page.substring(iRow, iEnd);
}

/// 窄屏那一支（`final compactRow = Column(` → `final row = Row(`）
String _compactSlice() {
  final iCompact = indexOfExactly(_page, 'final compactRow = Column(');
  final iRow = indexOfExactly(_page, 'final row = Row(');
  expect(iRow, greaterThan(iCompact));
  return _page.substring(iCompact, iRow);
}

/// 窄屏那个**横向滚动行**的子项列表
///
/// `SingleChildScrollView(` → `child: Row(` → `children: [`，逐层配平切出来。
/// 这是「顺序 + 算术」判据，不是真渲染几何（诚实标注，同 t68 E⑥）。
String _compactKids() {
  final compact = _compactSlice();
  final iScroll = indexOfExactly(compact, 'SingleChildScrollView(');
  final scroll = sliceBalanced(compact, iScroll, '(', ')');
  final iChildRow = indexOfExactly(scroll, 'child: Row(');
  final rowNode = sliceBalanced(scroll, iChildRow, '(', ')');
  final iChildren = indexOfExactly(rowNode, 'children: [');
  return sliceBalanced(rowNode, iChildren, '[', ']');
}

/// 把控件套进真实的壳（forui 主题 + material_ui 的 MaterialApp）
///
/// `CastButton` 只用 `Theme.of(context).colorScheme`，但宿主带 forui 无害。
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  A 组：宿主接线（源码级契约）
  // ═════════════════════════════════════════════════════════════════════

  group('A 组：宿主接线（源码级契约）', () {
    test('A① import 与调用点：四条参数各一份，按钮恰两枚', () {
      indexOfExactly(_page, "import 'cast/cast_button.dart';",
          why: '★ 宿主必须 import 控件（原先零 ui/cast/ import）');
      indexOfExactly(_page, 'onCast: _openCast,',
          why: '★ 宿主只给一个回调 —— 按钮自己决定弹面板还是重投');
      indexOfExactly(_page, "castUrl: _current?.url ?? '',",
          why: '★ 数据源必须**只有** `_current`（卡面：不要新建 _curStream）');
      indexOfExactly(
          _page, 'castHeaders: _current?.httpHeaders ?? const <String, String>{},',
          why: '★ headers 丢了就是电视端 403（INTEGRATION.md 四条易踩之一）');
      indexOfExactly(_page, 'castTitle: _castTitle,');
      indexOfExactly(_page, 'CastButton(', want: 2,
          why: '★ 窄屏 / 宽屏各一枚，照相机/齿轮的既有范式');
    });

    test('A② `_BottomBar` 是**纯新增**：四个构造参数全带默认值，四个字段齐备', () {
      // 带默认值 ⇒ 既有构造点（t57 / t73 / t78 那些只切源码的除外）一个都不用改
      indexOfExactly(_page, 'this.onCast,');
      indexOfExactly(_page, "this.castUrl = '',");
      indexOfExactly(_page, 'this.castHeaders = const <String, String>{},');
      indexOfExactly(_page, "this.castTitle = '',");
      indexOfExactly(_page, 'final VoidCallback? onCast;');
      indexOfExactly(_page, 'final String castUrl;');
      indexOfExactly(_page, 'final Map<String, String> castHeaders;');
      indexOfExactly(_page, 'final String castTitle;');
    });

    test('A③ 两支都门控 `castUrl.isNotEmpty`，且每枚按钮都紧跟门控', () {
      final iGate = indexOfExactly(_page, 'if (onCast != null && castUrl.isNotEmpty)',
          want: 2,
          why: '★ 窄屏 + 宽屏各一句；没流时传空串 ⇒ **不画**按钮（卡面「没流不给点」）');
      expect(iGate, greaterThan(0));
      // 每处 `CastButton(` 之前 200 字符内必须有一句门控 ——
      // 光数「两句门控 + 两枚按钮」还不够：它们可能各自待在不相干的地方。
      final gates = <int>[];
      var f = 0;
      while (true) {
        final i = _page.indexOf('if (onCast != null && castUrl.isNotEmpty)', f);
        if (i < 0) break;
        gates.add(i);
        f = i + 1;
      }
      final btns = <int>[];
      f = 0;
      while (true) {
        final i = _page.indexOf('CastButton(', f);
        if (i < 0) break;
        btns.add(i);
        f = i + 1;
      }
      expect(btns.length, 2);
      for (var k = 0; k < btns.length; k++) {
        expect(btns[k] - gates[k], greaterThan(0),
            reason: '★ 第 ${k + 1} 枚按钮必须排在同序号的**门控之后**');
        expect(btns[k] - gates[k], lessThan(200),
            reason: '★ 第 ${k + 1} 枚按钮离门控太远 ⇒ 中间塞了别的东西，门控不是它的');
      }
    });

    test('A④ 窄屏那枚排在「更多」和「画面缩放」**之后**（t68 E⑥ 硬约束）', () {
      final kids = _compactKids();
      final iMore = indexOfExactly(kids, 'Icons.more_vert',
          why: '★ 找不到「更多」⇒ 底栏结构变了，判据要重写');
      final iZoom = indexOfExactly(kids, 'Icons.zoom_in_map');
      final iCast = indexOfExactly(kids, 'CastButton(');
      expect(iCast, greaterThan(iMore),
          reason: '★ 投屏必须排在「更多」之后 —— 排在前面会把 tb.first 挤到前面，t68 E⑥ 红');
      expect(iCast, greaterThan(iZoom),
          reason: '★ 排在画面缩放之后（照相机/齿轮/缩放 是恒存在的固定项）');
      // ⚠️ `TextButton.icon(` 在 kids 里有 5 份（上一集/下一集/线路/换源/选集）
      //   ⇒ 只能取**首个下标**，不能 `indexOfExactly(..., want: 1)`。
      final tb = <int>[];
      var f = 0;
      while (true) {
        final i = kids.indexOf('TextButton.icon(', f);
        if (i < 0) break;
        tb.add(i);
        f = i + 1;
      }
      expect(tb.length, 5, reason: '★ 五个条件项都还在（两个受 hasStreams/hasEpisodes 门控）');
      expect(iCast, lessThan(tb.first),
          reason: '★ 且仍在五个条件项（上一集/下一集/线路/换源/选集）之前');
    });

    test('A⑤ 宽屏那枚排在弹幕设置（`Icons.tune`）之后', () {
      final wide = _wideSlice();
      final iTune = indexOfExactly(wide, 'Icons.tune');
      final iCast = indexOfExactly(wide, 'CastButton(');
      expect(iCast, greaterThan(iTune),
          reason: '★ 宽屏支沿用同一顺序：相机 → 齿轮 → 弹幕 → 投屏');
    });

    test('A⑥ 自证没破坏 t68 E⑥：三个固定项顺序与计数不变', () {
      // 这一段是 t68 E⑥ 的**同款坐标**（同一切片、同一套下标），
      // 它绿 + t68 E⑥ 绿 ⇒ 投屏那枚确实加在「不影响它」的位置上。
      final kids = _compactKids();
      final iCam = indexOfExactly(kids, 'Icons.photo_camera');
      final iGear = indexOfExactly(kids, 'Icons.settings');
      final iMore = indexOfExactly(kids, 'Icons.more_vert');
      expect(iCam, lessThan(iGear));
      expect(iGear, lessThan(iMore));
      final headCam = kids.substring(0, iCam);
      indexOfExactly(headCam, 'IconButton(',
          why: '★ 相机之前只该有它自己的 IconButton');
      expect(headCam.contains('Icons.'), isFalse);
      final headGear = kids.substring(0, iGear);
      indexOfExactly(headGear, 'IconButton(', want: 2);
      expect(headGear.contains('TextButton'), isFalse);
      final tb = <int>[];
      var f = 0;
      while (true) {
        final i = kids.indexOf('TextButton.icon(', f);
        if (i < 0) break;
        tb.add(i);
        f = i + 1;
      }
      expect(tb.length, 5);
      expect(tb.first, greaterThan(iMore));
    });

    test('A⑦ 铁律：宿主里**零**投屏状态机痕迹（不做假状态）', () {
      // 投屏中 / 失败 三态由 `CastButton` 自己按 `CastManager.session.phase` 算；
      // 宿主一旦自己写「投屏中」，就会在 SetAVTransportURI 成功但 Play 失败时骗人。
      const List<String> forbidden = <String>[
        'CastManager',
        'CastPhase',
        'sharedCastManager',
        'MediaProxy',
        'showCastDeviceSheet',
        'Icons.cast',
        '投屏中',
        '_curStream',
      ];
      for (final n in forbidden) {
        expect(countOf(_page, n), 0,
            reason: '★ 宿主里出现了「$n」—— 投屏的状态机与设备发现全在 lib/ui/cast/ 里，宿主只给数据');
      }
    });

    test('A⑧ 「没流不给点」由**不画按钮**承担，且校验链是两态', () {
      final iOpen = indexOfExactly(_page, 'void _openCast()');
      final body = _page.substring(iOpen, _page.indexOf('\n  }', iOpen));
      expect(body.contains("final st = _current;"), isTrue,
          reason: '★ 唯一数据源：现成的 `_current`（卡面明令不要新建字段）');
      indexOfExactly(body, "_flash('还没有正在播的流（先起播）')",
          why: '★ 照抄 :3522 `_downloadClip` 的「没流就不给点」范式');
      indexOfExactly(body, "st.url.startsWith('http://')");
      indexOfExactly(body, "_flash('这个地址不能投屏（只支持 http/https）')",
          why: '★ 本地文件 / magnet / rtsp 投过去只会让电视报 716');
      expect(body.contains('setState'), isFalse,
          reason: '★ 校验里**不许**有任何乐观显示（铁律）');
    });

    test('A⑨ 标题三级回退：当前集标题 → 直播标题 → 投屏', () {
      final iTitle = indexOfExactly(_page, 'String get _castTitle');
      final body = _page.substring(iTitle, _page.indexOf('\n  }', iTitle));
      expect(body.contains('_currentEpisodeTitle'), isTrue,
          reason: '★ 点播优先用剧集标题');
      expect(body.contains('_liveTitle'), isTrue, reason: '★ 直播用频道标题');
      expect(body.contains("'投屏'"), isTrue, reason: '★ 都没有时给一个中性名字');
      indexOfExactly(_page, '_castTitle', want: 2,
          why: '★ 定义一处 + 调用点一处（多一处就是有人又抄了一份标题逻辑）');
    });

    test('A⑩ 既有门控原样：480 阈值 / fits / 窄屏一根滑杆且无 tune', () {
      indexOfExactly(_page, 'const double _kBottomBarFitWidth = 480;');
      indexOfExactly(_page, 'final fits = constraints.maxWidth.isFinite &&');
      final compact = _compactSlice();
      indexOfExactly(compact, 'Slider(');
      indexOfExactly(compact, 'max: 100,');
      indexOfExactly(compact, 'Icons.tune', want: 0,
          why: '★ compactRow 里不许有 tune —— 它已经进「更多」菜单');
      final wide = _wideSlice();
      indexOfExactly(wide, 'Icons.photo_camera');
      indexOfExactly(wide, 'Icons.settings');
      indexOfExactly(wide, 'Icons.tune');
      indexOfExactly(wide, "Text('选集'");
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  B 组：`CastButton` 两态真渲染（**零网络**，见文件头）
  // ═════════════════════════════════════════════════════════════════════

  group('B 组：CastButton 两态（真渲染，零网络）', () {
    testWidgets('B① 空 url：控件照画、且**不**自己禁用（宿主靠不画来兜）', (t) async {
      await t.pumpWidget(_host(const CastButton(url: '')));
      expect(find.byType(CastButton), findsOneWidget);
      expect(find.byTooltip('投屏到电视'), findsOneWidget,
          reason: '★ 非 busy / 非 active / 非 failed 时的 tooltip');
      final ib = t.widget<IconButton>(find.byType(IconButton));
      // ★ 如实记录现状：`CastButton` **不看** url 是否为空来决定禁用态
      //   （`onPressed: _busy ? null : _onTap`，禁用只来自 `_busy`）。
      //   所以「没流不给点」**必须**由宿主的门控 `castUrl.isNotEmpty` 承担 ——
      //   宿主只传空串的话，用户会看到一枚能点的按钮，点下去才弹
      //   「这个地址不能投屏」。
      expect(ib.onPressed, isNotNull,
          reason: '★ 控件在空 url 下仍可点 ⇒ 宿主绝不能拿空串兜底（A③ 钉的就是这句）');
      expect(ib.tooltip, '投屏到电视');
    });

    testWidgets('B② 有流：url / headers / title 原样交给控件（宿主传什么就投什么）', (t) async {
      const url = 'https://example.invalid/live/a.m3u8';
      const headers = <String, String>{'Referer': 'https://example.invalid/'};
      await t.pumpWidget(_host(const CastButton(
        url: url,
        headers: headers,
        title: '第 3 集',
      )));
      final cb = t.widget<CastButton>(find.byType(CastButton));
      expect(cb.url, url);
      expect(cb.headers, headers,
          reason: '★ headers 丢了就是电视端 403');
      expect(cb.title, '第 3 集');
      expect(find.byTooltip('投屏到电视'), findsOneWidget);
      // ★ 绝不 tap：那会走 `showCastDeviceSheet` 真发 SSDP 包。
    });

    testWidgets('B③ 默认 showLabel=false ⇒ 渲染的是**裸 IconButton**（无 TextButton / 无 Text）',
        (t) async {
      await t.pumpWidget(_host(const CastButton(url: 'https://example.invalid/a.m3u8')));
      expect(find.byType(TextButton), findsNothing,
          reason: '★ 底栏 headGear 里不许有 TextButton（t68 E⑥）；带标签的那支是给别处用的');
      expect(find.byType(Text), findsNothing,
          reason: '★ 裸 IconButton 不该带任何文本 —— 带标签会让底栏宽度账失真');
      expect(find.byIcon(Icons.cast), findsOneWidget);
    });

    test('B④ 未接线项（如实记录）：`CastStatusBar` 本卡没接', () {
      // 卡面把状态条列为「可选」。没接就是没接 —— 钉在这里，
      // 免得以后有人以为底栏上有投屏进度条。
      expect(countOf(_page, 'CastStatusBar'), 0,
          reason: '★ 若哪天接上了，把这条改成「恰好一处」并补渲染判据');
    });
  });
}
