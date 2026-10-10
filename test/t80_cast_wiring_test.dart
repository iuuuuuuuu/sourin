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

/// 宿主源码长度（几处切片用，避免硬编码行号）
final int iPageEnd = _page.length;

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  A 组：宿主接线（源码级契约）
  // ═════════════════════════════════════════════════════════════════════

  group('A 组：宿主接线（源码级契约）', () {
    test('A① import 与调用点：四条参数各一份，按钮恰好一枚', () {
      indexOfExactly(_page, "import 'cast/cast_button.dart';",
          why: '★ 宿主必须 import 控件（原先零 ui/cast/ import）');
      indexOfExactly(_page, 'onTap: _openCast,',
          why: '★ 宿主只给一个回调 —— 按钮自己决定弹面板还是重投');
      indexOfExactly(_page, "final url = _current?.url ?? '';",
          why: '★ 数据源必须**只有** `_current`（卡面：不要新建 _curStream）');
      indexOfExactly(
          _page, 'headers: _current?.httpHeaders ?? const <String, String>{},',
          why: '★ headers 丢了就是电视端 403（INTEGRATION.md 四条易踩之一）');
      indexOfExactly(_page, 'title: _castTitle,');
      // ★ 2026-10-10：底栏瘦身后投屏从「窄屏一枚 + 宽屏一枚」变成「更多里一枚」
      indexOfExactly(_page, 'CastButton(', want: 1,
          why: '★ 全宿主只该有一枚 CastButton（在「更多」浮层的那一项里）');
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

    test('A③ 没流时整项不出现（门控守着唯一的入口）', () {
      /*
       * ★ 2026-10-10：门控从「窄屏/宽屏两处 `if (... && castUrl.isNotEmpty)`」
       *   收成一处 —— `castEntry` 在 url 为空时直接 `return null`，
       *   菜单里那一行 `if (castEntry case final e?) e,` 于是不插入任何东西。
      *   语义完全等价（「没流不给点」），但门控从两处减到一处。
       */
      final entry = _page.substring(
          _page.indexOf('MoreMenuEntry? get castEntry'), iPageEnd);
      expect(entry.contains('if (url.isEmpty) return null;'), isTrue,
          reason: '★ 门控必须在入口本身（而不是散落在两处布局分支里）');
      // 且插入点必须真的判空
      expect(_page.contains('if (castEntry case final e?) e,'), isTrue,
          reason: '★ 菜单插入点必须判空（否则 null 会被当成一项插进去）');
    });

    test('A④ 投屏入口在「更多」里，且用真的 CastButton（不是自己画的图标）', () {
      /*
       * ★ 2026-10-10：随底栏瘦身，投屏从「底栏上一枚按钮」变成「更多里的一项」。
       *   原来这条守的是「窄屏那枚排在『更多』和『画面缩放』之后」——
       *   那个坐标随底栏重写已不存在。真正的不变更是：
       *   **投屏必须仍然用真的 `CastButton`**（代理 / 扫描电视 / 状态轮询都在它内部），
       *   而不是宿主自己画一个图标。
       */
      final iEntry = _page.indexOf('MoreMenuEntry? get castEntry');
      expect(iEntry, greaterThan(0), reason: '★ 投屏入口必须还在');
      final entry = _page.substring(iEntry, iPageEnd);
      indexOfExactly(entry, 'CastButton(',
          why: '★ 必须用真的 CastButton —— 代理与状态机都在它内部');
      indexOfExactly(entry, 'trailing: CastButton(',
          why: '★ 它挂在 trailing 上（整行不可点，动作在按钮本身）');
      // 没有流 ⇒ 整项不出现（原来门控写两处，现在返回 null 一处）
      indexOfExactly(entry, 'if (url.isEmpty) return null;',
          why: '★ 没流时必须整项不出现（卡面「没流不给点」）');
    });

    test('A⑤ 投屏与其它低频项同组（都在「更多」里）', () {
      /*
       * ★ 2026-10-10：原来这条守的是「宽屏那枚投屏排在弹幕设置之后」——
       *   那个「宽屏支」随底栏瘦身整个不存在了。
       *   真正的不变更是：**投屏与弹幕设置、截图、缩放同属低频组**，
       *   都收在「更多」浮层里，一枚都不留在底栏上。
       */
      final entry = _page.substring(
          _page.indexOf('MoreMenuEntry? get castEntry'), iPageEnd);
      expect(entry.contains('icon: Icons.cast'), isTrue,
          reason: '★ 菜单项需要一个图标；用 Icons.cast 是对的');
      // 弹幕设置同样只在菜单里
      expect(_page.contains("label: '弹幕设置'"), isTrue,
          reason: '★ 弹幕设置应当也在「更多」浮层里（与投屏同组）');
      // 底栏源码里一枚 CastButton 都没有（真按钮只在宿主的菜单项里）
      // ⚠️ 必须**剥掉注释**再数：`player_bottom_bar.dart` 里有一处注释
      //   提到了 `CastButton`（说明数据从哪来），文本计数会把它算进去。
      final bar = stripComments(
          File('lib/ui/player/player_bottom_bar.dart').readAsStringSync());
      expect(countOf(bar, 'CastButton'), 0,
          reason: '★ 底栏不画投屏按钮（它在「更多」里，由宿主提供）');
    });

    test('A⑥ 低频项顺序：投屏在「更多」组里，且没碰常驻三项', () {
      /*
       * ★ 2026-10-10（Owner 第 12 条底栏瘦身）：投屏不再是底栏上「窄屏一枚 +
       *   宽屏一枚」的两枚按钮，而是「更多」浮层里的一项（`castEntry`）。
       *   原来这条守的是「投屏那枚插在不影响 t68 E⑥ 的位置」——
       *   那个坐标已经不存在，**要守的不变量随之变了**：
       *   投屏必须待在「更多」里（低频），且不许挤进底栏常驻的三项。
       */
      expect(_page.contains('MoreMenuEntry? get castEntry'), isTrue,
          reason: '★ 投屏入口必须仍然是「更多」浮层里的一项');
      // 常驻三项（播放/音量/倍速）里不许出现投屏
      final iPrimary = _page.indexOf('final primary = <Widget>[');
      final bar = File('lib/ui/player/player_bottom_bar.dart').readAsStringSync();
      final iBarPrimary = bar.indexOf('final primary = <Widget>[');
      expect(iBarPrimary, greaterThan(0));
      final primaryBlock = bar.substring(
          iBarPrimary, bar.indexOf('final secondary = <Widget>['));
      expect(primaryBlock.contains('cast'), isFalse,
          reason: '★ 投屏是低频项，不该出现在底栏常驻行里');
      expect(_page.contains('if (castEntry case final e?) e,'), isTrue,
          reason: '★ 菜单里必须真的把它插进去（那一行就是插入口）');
    });

    test('A⑦ 铁律：宿主里**零**投屏状态机痕迹（不做假状态）', () {
      // 投屏中 / 失败 三态由 `CastButton` 自己按 `CastManager.session.phase` 算；
      // 宿主一旦自己写「投屏中」，就会在 SetAVTransportURI 成功但 Play 失败时骗人。
      //
      // ★ 2026-10-10：`Icons.cast` 从禁列里移出 —— 新的「更多」菜单项**合法地**
      //   用了它（`castEntry` 里 `icon: Icons.cast`）。原先禁它是因为那时
      //   底栏上那枚按钮由 CastButton 自己画图标，宿主不该再画一个。
      //   菜单项需要一个图标，用 `Icons.cast` 是对的。
      //   ⚠️ 真正的禁令没变：宿主不许**自己实现**投屏状态机。
      const List<String> forbidden = <String>[
        'CastManager',
        'CastPhase',
        'sharedCastManager',
        'MediaProxy',
        'showCastDeviceSheet',
        '投屏中',
        '_curStream',
      ];
      for (final n in forbidden) {
        expect(countOf(_page, n), 0,
            reason: '★★ 宿主里出现「$n」⇒ 自己做假状态了（真状态在 CastManager）');
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
      /*
       * ★ 2026-10-10：`_castTitle` 的引用数从 2 变成 3 —— 底栏瘦身时
       *   旧的 `castTitle:` 调用点还在（那条线已被删），新的 `castEntry` 里
       *   又用了一次。⇒ 「恰好 N 处」这种计数判据在重构后必然假红，
       *   改成「**定义只有一处**」+「每个调用点都真的从它取值」。
       */
      final iTitle = indexOfExactly(_page, 'String get _castTitle');
      final body = _page.substring(iTitle, _page.indexOf('\n  }', iTitle));
      expect(body.contains('_currentEpisodeTitle'), isTrue,
          reason: '★ 点播优先用剧集标题');
      expect(body.contains('_liveTitle'), isTrue, reason: '★ 直播用频道标题');
      expect(body.contains("'投屏'"), isTrue, reason: '★ 都没有时给一个中性名字');
      // 定义只有一处（不许有人再抄一份标题逻辑）
      indexOfExactly(_page, 'String get _castTitle', want: 1,
          why: '★ 标题回退逻辑必须只有一份');
    });

    test('A⑩ 底栏的宽/窄分支与滑杆量程（与投屏无关，守的是别被改坏）', () {
      /*
       * ★ 2026-10-10：原来这条钉的是旧底栏的 `480` 阈值 / `fits` /
       *   compactRow 一根��杆 / 宽屏三固定项。新底栏换成了
       *   `final wide = avail >= _kBarRowWidth;` 的两分支写法，
       *   常驻三项是 播放/音量/倍速（不再是 相机/齿轮/弹幕）。
       *   ⇒ 判据按新结构重写，守的还是同一类东西：**别把布局改坏**。
       */
      final bar = File('lib/ui/player/player_bottom_bar.dart').readAsStringSync();
      indexOfExactly(bar, 'final wide = avail >= _kBarRowWidth;',
          why: '★ 宽/窄分支必须还在（Owner 要底栏在窄屏也放得下）');
      indexOfExactly(bar, 'if (wide) {');
      // 滑杆：音量 max:100 一根、缩放 max:200 一根，各只该有一根
      indexOfExactly(bar, 'max: 100,', want: 1, why: '★ 音量滑杆只该一根');
      indexOfExactly(bar, 'max: 200,', want: 1, why: '★ 缩放滑杆只该一根');
      expect(bar.contains('Icons.tune'), isFalse,
          reason: '★ 弹幕设置已进「更多」菜单，不该留在底栏');
      // 常驻三项按顺序：播放/暂停 → 音量 → 倍速。
      // ⚠️ 必须在 `primary` **切片内**量：`倍速` 这个词在文件里还出现在
      //   上面那个 popover 的定义处（258 行），全文件 indexOf 会量错。
      final iPrimary = bar.indexOf('final primary = <Widget>[');
      final iSecondary = bar.indexOf('final secondary = <Widget>[');
      expect(iPrimary, greaterThan(0));
      expect(iSecondary, greaterThan(iPrimary));
      final primaryBlock = bar.substring(iPrimary, iSecondary);
      final iPlay = primaryBlock.indexOf("tooltip: '播放 / 暂停'");
      final iVol = primaryBlock.indexOf('_VolumeControl(');
      final iRate = primaryBlock.indexOf("tooltip: '倍速'");
      expect(iPlay, greaterThan(0), reason: '★ 常驻行里必须有播放/暂停');
      expect(iVol, greaterThan(iPlay), reason: '★ 常驻三项顺序：播放 → 音量 → 倍速');
      expect(iRate, greaterThan(iVol));
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
