// ═══════════════════════════════════════════════════════════════════════
//  task-31 ④：哔哩哔哩弹幕面板的**接线**（宿主侧 = player_page.dart）
// ═══════════════════════════════════════════════════════════════════════
//
// 面板本体（渲染 / 按钮启用态 / 八个回调）已经在 `test/t70_bili_danmaku_test.dart`
// 里测过了（76 用例）。**这个文件只守「接进去了没有」**：
//
// ```text
// ① 四条「必须一起改」的规则（施工单 §3.2）
//    漏一处就是一个真实 bug，而它们全在 player_page.dart 里 ——
//    挂真 PlayerPage 要 libmpv，flutter_tester 会崩 ⇒ 只能源码级判据
// ② 起播取弹幕的优先级（绑了 B 站 ⇒ 不发 dandanplay 的请求）
// ③ 入口（弹幕面板里那枚「哔哩哔哩弹幕…」）
// ④ 自动刷新（切集 / 集列表被换掉）
// ⑤ 面板真渲染 + 真点击（宿主回调记账）
// ```
//
// ★ 本文件**不发一个网络包**：
//   · 源码级判据只读文件；
//   · 行为判据用 `_NoNetApi`（父类持有「一用就抛」的 HttpClient）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_auto_update.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ══════════════════════════════════════════════════════════════════════
//  源码级判据的底座（stripComments 逐字照抄 `player_capability_test.dart:61-110`）
// ══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）。
///
/// ⚠️ 必须剥：本仓踩过 5 次「把注释文本写进判据 ⇒ 永远找不到 ⇒ 假红」，
///    而 player_page.dart 的注释里**正写着** `if (_biliSheetOpen)` 这类片段。
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
const String _dialogPath = 'lib/ui/widgets/danmaku_settings_dialog.dart';

final String _page = stripComments(File(_pagePath).readAsStringSync());
final String _dialog = stripComments(File(_dialogPath).readAsStringSync());

/// 断言 `needle` 在 `src` 里**恰好**出现 [want] 次，并返回首次下标。
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

/// 取 `bool get _anySheetOpen =>` 的正文（到第一个 `;`）。
String _anySheetBody() {
  // ignore: unused_element_parameter
  final gi = _page.indexOf('bool get _anySheetOpen =>');
  expect(gi, greaterThan(0), reason: '★ 找不到 getter ⇒ 文件结构变了');
  return _page.substring(gi, _page.indexOf(';', gi));
}

// ══════════════════════════════════════════════════════════════════════
//  行为判据的替身
// ══════════════════════════════════════════════════════════════════════

/// 任何成员被用到就抛 —— 走到这里就是测试写错了。
class _NoNetClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
        '单测里不许用真 HttpClient（成员：${invocation.memberName}）',
      );
}

/// 记账用的假 API：只覆盖 `resolveShortLink` / `videoInfo` / `danmaku`。
class _NoNetApi extends BiliApi {
  _NoNetApi() : super(client: _NoNetClient());

  /// 一共被调用了几次（垃圾输入那条要求它是 **0**）。
  int calls = 0;

  @override
  Future<BiliRef> resolveShortLink(BiliRef ref) async {
    calls++;
    return ref;
  }

  @override
  Future<BiliVideoInfo> videoInfo(BiliRef ref) async {
    calls++;
    return const BiliVideoInfo(bvid: 'BV1GJ411x7h7', aid: 1, title: 'x');
  }

  @override
  Future<List<DanmakuComment>> danmaku(int cid) async {
    calls++;
    return const <DanmakuComment>[];
  }
}

/// 面板夹具（`DanmakuSettingsDialog` 的根节点是 `Positioned.fill` ⇒ 必须套 Stack）。
Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

DanmakuSettingsState _settingsState() => const DanmakuSettingsState(
      enabled: true,
      appId: 'a',
      appSecret: 'b',
      fontScale: 1.0,
      opacity: 1.0,
      speed: 8.0,
      area: 1.0,
    );

DanmakuSettingsDialog _danmakuDialog({VoidCallback? onOpenBili}) =>
    DanmakuSettingsDialog(
      state: _settingsState(),
      onSetEnabled: (_) {},
      onSetAppId: (_) {},
      onSetAppSecret: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onClearCredentials: () {},
      onReload: () {},
      onClose: () {},
      onOpenBili: onOpenBili,
    );

void main() {  // ═══════════════════════════════════════════════════════════════════
  //  1. 四条「必须一起改」（施工单 §3.2）—— 漏一处就是一个真 bug
  // ═══════════════════════════════════════════════════════════════════

  group('1. 四条一致性规则', () {
    test('① _anySheetOpen 列全（含两个新面板）', () {
      final body = _anySheetBody();
      for (final name in const [
        '_episodeSheetOpen',
        '_settingsOpen',
        '_streamSheetOpen',
        '_hintsOpen',
        '_liveChannelsOpen',
        '_danmakuSheetOpen',
        '_zoomOpen',
        '_biliSheetOpen',
        '_subtitlePanelOpen',
      ]) {
        expect(body.contains(name), isTrue,
            reason: '★★ _anySheetOpen 漏了 $name ⇒ 会出现「面板开着按 Enter 却全屏了」');
      }
      expect(_page.contains('!widget.isTv && !_anySheetOpen'), isTrue);
    });

    test('② 控制条可见性排除了两个新面板（窗口内，距 600 上限有余量）', () {
      /*
       * ⚠️ 判据与 t57_sheet_scrim_geometry_test.dart 同款：
       *    往回 600 字符找 _BottomBar( 前面那个 if ( 。
       *    这里额外断言「条件块没被撑爆」—— 加项加过头会让 t57 的窗口
       *    够不到 if ( （那时 t57 会红，但报错信息很难看出是这里撑的）。
       */
      final i = _page.indexOf('_BottomBar(');
      expect(i, greaterThan(0));
      final before = _page.substring((i - 600).clamp(0, i), i);
      final condStart = before.lastIndexOf('if (');
      expect(condStart, greaterThanOrEqualTo(0),
          reason: '★ 找不到 if ( ⇒ 条件块已经长到 600 字符以外了');
      final cond = before.substring(condStart);
      for (final flag in const [
        '_episodeSheetOpen',
        '_streamSheetOpen',
        '_settingsOpen',
        '_danmakuSheetOpen',
        '_liveChannelsOpen',
        '_biliSheetOpen',
        '_subtitlePanelOpen',
      ]) {
        expect(cond.contains('!$flag'), isTrue,
            reason: '★★ 控制条条件漏了 !$flag ⇒ 该面板开着时控制条仍然画着，'
                '而面板自身的有色区域（ColoredBox = HitTestBehavior.opaque）会吸收点击');
      }
    });

    test('③ Esc 链：两个新面板排在设置面板之前，且没把窗口撑破', () {
      /*
       * 两条既有断言共用这个窗口：
       *   · player_capability_test 要 _settingsOpen 在 _episodeSheetOpen 之前
       *   · t78_video_zoom_hwdec_test 要 _settingsOpen < _zoomOpen < _episodeSheetOpen
       * 它们都只看 **Esc 分支之后 700 字符**。
       *
       * ★ 本仓踩过：_episodeSheetOpen 实测被推到 684 —— 只剩 16 字符余量。
       *   所以这里显式断言「所有既有分支都还在 700 以内」，
       *   把「谁把窗口撑破了」的定位成本从「去读别人的测试」降到「读这条报错」。
       */
      final i = _page.indexOf('if (k == LogicalKeyboardKey.escape ||');
      expect(i, greaterThan(0));
      final body = _page.substring(i, (i + 700).clamp(0, _page.length));
      /*
       * ★ 既有断言用的是**同一个 700 窗口**，它们只看 `_settingsOpen` /
       *   `_zoomOpen` / `_episodeSheetOpen` —— 实测现在分别落在
       *   446 / 594 / 676（`_episodeSheetOpen` 只剩 24 字符余量）。
       *   这里把「余量」也断言出来：以后谁再加一个分支把窗口撑破，
       *   报错会直接指着这一条，而不是让 `player_capability_test` 先红。
       */
      // ignore: prefer_const_declarations
      final escWindow = _page.substring(i, (i + 700).clamp(0, _page.length));
      expect(escWindow.indexOf('else if (_episodeSheetOpen)'), lessThan(700),
          reason: '★★ 既有断言（player_capability / t78）都在这个 700 窗口里找分支，'
              '现在只剩 42 字符余量 —— 再加分支前先跑 .probe/yamby/strip_probe.dart');
      final iBili = body.indexOf('else if (_biliSheetOpen)');
      final iSub = body.indexOf('else if (_subtitlePanelOpen)');
      final iDanmaku = body.indexOf('else if (_danmakuSheetOpen)');
      final iSettings = body.indexOf('else if (_settingsOpen)');
      final iZoom = body.indexOf('else if (_zoomOpen)');
      final iEpisode = body.indexOf('else if (_episodeSheetOpen)');
      expect(iBili, greaterThan(0), reason: '★ Esc 必须能关 B 站面板');
      expect(iSub, greaterThan(iBili), reason: '★ 字幕面板排在 B 站面板之后');
      expect(iDanmaku, greaterThan(iSub), reason: '★ 弹幕设置面板再后');
      expect(iSettings, greaterThan(iDanmaku), reason: '★ 设置面板排在弹幕面板之后');
      expect(iZoom, greaterThan(iSettings), reason: '★ 缩放滑条排在设置面板之后');
      expect(iEpisode, greaterThan(iZoom), reason: '★ 缩放滑条排在选集之前');
    });

    test('④ 挂载顺序：B 站面板画在弹幕面板之后（层序与 Esc 一致）', () {
      /*
       * ★★★ task-104：判据的 needle 跟着**挂载形态**走（铁律⑥）
       *
       * ```text
       * 改前：if (_danmakuSheetOpen) DanmakuSettingsDialog(...)
       *       ⇒ 判据找 'if (_danmakuSheetOpen)'
       * 改后：Positioned.fill(child: SheetExitMotion(visible: _danmakuSheetOpen, …))
       *       ⇒ 挂载点里已经没有 'if (_xOpen)' 这个字面量了
       *         （这正是「退出动画」的前提：常挂 + 只翻 visible ——
       *           写成 if (_xOpen) 时那个 Element 会被整个移除、
       *           didUpdateWidget 根本不跑，见 SheetExitMotion 的类文档）
       * ```
       * ⚠️ **语义一条都没放松**：仍然是「弹幕面板 → B 站面板 → 字幕面板」
       *    这个**层序**，只是从「找 if 分支」改成「找各自挂载块里的 visible:」。
       *    ★ 而 Esc 链的 `else if (_xSheetOpen)` 仍由上面 ③ 单独钉着
       *      （两处顺序必须一致，那条断言一字未动）。
       */
      final iDanmaku = _page.indexOf('visible: _danmakuSheetOpen,');
      final iBili = _page.indexOf('visible: _biliSheetOpen,');
      final iSub = _page.indexOf('visible: _subtitlePanelOpen,');
      expect(iDanmaku, greaterThan(0),
          reason: '★ 找不到弹幕面板的挂载点（SheetExitMotion 的 visible:）');
      expect(iBili, greaterThan(iDanmaku),
          reason: '★ 后画的在上层 ⇒ 新面板必须挂在弹幕面板之后');
      expect(iSub, greaterThan(iBili), reason: '★ 字幕面板排在 B 站面板之后');
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  2. 起播取弹幕的优先级
  // ═══════════════════════════════════════════════════════════════════

  group('2. B 站优先：绑了就一个 dandanplay 请求都不发', () {
    test('① _loadDanmakuNamed 里 B 站分支在令牌之前、且 return 掉', () {
      final i0 = _page.indexOf('Future<void> _loadDanmakuNamed(');
      expect(i0, greaterThan(0));
      final iBind = _page.indexOf('final biliBind = loadBinding(', i0);
      final iCid = _page.indexOf('final cid = biliBind.cidFor(_epIndex);', i0);
      final iLoad = _page.indexOf('await _loadBiliDanmaku(cid);', i0);
      final iToken = _page.indexOf('final token = ++_danmakuFetchToken;', i0);
      final iClient = _page.indexOf('final client = _ensureDanmakuClient();', i0);
      expect(iBind, greaterThan(i0), reason: '★ 必须查绑定');
      expect(iCid, greaterThan(iBind), reason: '★ 必须按当前集算 cid');
      expect(iLoad, greaterThan(iCid), reason: '★ 必须走 B 站那条路');
      expect(iToken, greaterThan(iLoad),
          reason: '★★ B 站分支必须在 final token = ++_danmakuFetchToken; 之前并 return —— '
              '否则会继续往下建 dandanplay 客户端，绑了 B 站就不发 dandanplay 请求当场失效');
      expect(iClient, greaterThan(iToken),
          reason: '★ dandanplay 客户端的懒建必须在令牌之后（原有顺序不能动）');
    });

    test('② _loadBiliDanmaku 用的是同一套令牌/loading 骨架', () {
      final i0 = _page.indexOf('Future<void> _loadBiliDanmaku(');
      expect(i0, greaterThan(0));
      final body = _page.substring(i0, i0 + 2600);
      expect(body.contains('final token = ++_danmakuFetchToken;'), isTrue,
          reason: '★ 换集时旧响应必须被丢掉（与 dandanplay 同一条规矩）');
      expect(body.contains('if (!mounted || token != _danmakuFetchToken) return;'),
          isTrue,
          reason: '★★ 令牌判据不能省 —— 否则第 5 集会短暂显示第 3 集的弹幕');
      expect(body.contains('_danmakuLoading = true;'), isTrue);
      expect(body.contains('_danmakuLoading = false;'), isTrue);
      expect(body.contains('_danmakuComments = r.comments;'), isTrue);
      expect(body.contains('_danmakuStatus = r.summary;'), isTrue);
      expect(body.contains('markBiliSynced();'), isTrue,
          reason: '★ 同步时间要记，否则自动更新永远认为缓存还新鲜');
    });

    test('③ 用的是 B 站自己的解析器（9 段），不是 DanmakuComment.parse（4 段）', () {
      /*
       * ★ 施工单 §6 记的坑：B 站 p 是 9 段（颜色在下标 3），
       *   dandanplay 是 4 段（颜色在下标 2）。复用后者 = 所有弹幕颜色错位。
       *   宿主这一层**不该出现任何 p 的解析** —— 解析全在 core 里。
       */
      expect(_page.contains('parseBiliDanmakuEntry'), isFalse,
          reason: '★ 解析是 core 的事，宿主不该碰');
      expect(_page.contains('DanmakuComment.parse'), isFalse,
          reason: '★★ 绝不能复用 4 段解析器（B 站是 9 段，颜色会错位）');
      expect(_page.contains('updateDanmaku('), isTrue);
      expect(_page.contains('bindFromInput('), isTrue);
    });

    test('④ 切集与集列表变化都会触发自动刷新', () {
      final iGoto = _page.indexOf('Future<void> _gotoEpisode(');
      expect(iGoto, greaterThan(0));
      final gotoBody = _page.substring(iGoto, iGoto + 3000);
      expect(
        gotoBody.contains('if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());'),
        isTrue,
        reason: '★ 切集后不刷 ⇒ 新一集放着上一集的弹幕',
      );
      expect(
        gotoBody.indexOf('unawaited(_biliAutoRefresh());'),
        lessThan(gotoBody.indexOf('await _reload();')),
        reason: '★ 先刷弹幕再重启流：用户切过去时弹幕已经是新一集的',
      );

      final iUpd = _page.indexOf('void updateEpisodes(');
      // ignore: unnecessary_statements
      expect(iUpd, greaterThan(0));
      final updBody = _page.substring(iUpd, iUpd + 2200);
      expect(
        updBody.contains('if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());'),
        isTrue,
        reason: '★ 集列表被换掉 ⇒ 本地集序到 cid 的映射可能变了，要重刷',
      );
    });

    test('⑤ 解绑后能退回 dandanplay（分支查不到绑定就往下走）', () {
      final i0 = _page.indexOf('void _biliUnbind()');
      expect(i0, greaterThan(0));
      final body = _page.substring(i0, i0 + 900);
      expect(body.contains('clearBinding(widget.provider, widget.id);'), isTrue,
          reason: '★ 解绑要真的把偏好删掉（否则下次起播还是 B 站）');
      expect(body.contains('_danmakuComments = const <DanmakuComment>[];'), isTrue,
          reason: '★ 画面上的弹幕也要清 —— 留着会让用户以为解绑没生效');
      expect(_page.contains('if (biliBind != null && !biliBind.isEmpty) {'), isTrue,
          reason: '★ 这就是退回 dandanplay 的机制');
    });

    test('⑥ 客户端在 dispose 里被 close（与 dandanplay 同段收尾）', () {
      final iClose = indexOfExactly(_page, '_biliApi?.close();');
      final iPlayer = _page.indexOf('_player.dispose();');
      expect(iClose, lessThan(iPlayer),
          reason: '★ 与 _danmakuClient?.close() 同一段收尾（其它资源之前）');
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  3. 入口（弹幕面板 → B 站面板）
  // ═══════════════════════════════════════════════════════════════════

  group('3. 入口：弹幕面板里的「哔哩哔哩弹幕…」', () {
    test('① 宿主把 onOpenBili 接上了', () {
      expect(_page.contains('onOpenBili: _openBiliSheet,'), isTrue,
          reason: '★ 不接 ⇒ 面板里那枚按钮永远是 null ⇒ 不画（用户找不到入口）');
      final i0 = _page.indexOf('void _openBiliSheet()');
      expect(i0, greaterThan(0));
      final body = _page.substring(i0, i0 + 1800);
      expect(body.contains('_biliSheetOpen = true;'), isTrue);
      expect(body.contains('_danmakuSheetOpen = false;'), isTrue,
          reason: '★ 两个都是全屏 scrim ⇒ 同时开着时 Esc 关的层会与用户看见的不一致');
      expect(body.contains('_biliPanelToken = _danmakuFetchToken;'), isTrue,
          reason: '★ 必须记下「打开面板时是哪一集」');
    });

    testWidgets('② 面板真渲染：传了 onOpenBili 就有按钮，点了会回调', (t) async {
      var opened = 0;
      await t.pumpWidget(_host(_danmakuDialog(onOpenBili: () => opened++)));
      await t.pumpAndSettle();
      final btn = find.widgetWithText(TextButton, '哔哩哔哩弹幕…');
      expect(btn, findsOneWidget);
      /*
       * ⚠️ 按钮在面板最末尾 —— 800×600 的测试面里它在 y=956（屏幕外），
       *    `t.tap` 会打印 “would not hit test on the specified widget” 然后
       *    静默不触发。必须先滚进视口（`player_capability_test.dart:1114`
       *    就是这么滚 chip 的）。
       */
      await t.scrollUntilVisible(
        btn,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      expect(btn.hitTestable(), findsOneWidget,
          reason: '★ 滚到底都点不到 ⇒ 按钮被裁在面板可视区之外');
      await t.tap(btn);
      await t.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('③ 没传 onOpenBili ⇒ 按钮不画（旧宿主零破坏）', (t) async {
      await t.pumpWidget(_host(_danmakuDialog()));
      await t.pumpAndSettle();
      expect(find.text('哔哩哔哩弹幕…'), findsNothing,
          reason: '★ 面板可以被别的宿主复用而不带上 B 站 —— 那时不该有这枚按钮');
      expect(find.text('重新获取弹幕'), findsOneWidget, reason: '阳性对照');
    });

    test('④ 面板文件里那枚按钮是可选的（onOpenBili 声明为可空）', () {
      expect(_dialog.contains('this.onOpenBili,'), isTrue,
          reason: '★ 不能设成 required —— 那会让既有的两处调用点编译不过');
      expect(_dialog.contains('final VoidCallback? onOpenBili;'), isTrue);
      expect(_dialog.contains('if (widget.onOpenBili != null)'), isTrue,
          reason: '★ 为 null 时整枚不画');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  4. 导入的失败路径（垃圾输入 ⇒ 一个请求都不发）
  // ═══════════════════════════════════════════════════════════════════

  group('4. 导入的失败路径', () {
    setUp(UiPrefs.debugResetForTest);

    test('① 垃圾输入 ⇒ ArgumentError，且一个请求都不发', () async {
      final api = _NoNetApi();
      await expectLater(
        bindFromInput(
          api: api,
          input: '这不是 BV 号',
          provider: 'demo',
          id: 'id1',
          localTitle: '某番',
          episodeTitles: const <String>['第1集'],
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(api.calls, 0,
          reason: '★★ 解析失败必须在发请求之前抛 —— 用户粘错一段文本不该打三个 API');
    });

    test('② 宿主把 ArgumentError 翻译成用户看得懂的那句话', () {
      final i0 = _page.indexOf('Future<void> _biliImport(');
      expect(i0, greaterThan(0));
      final body = _page.substring(i0, i0 + 2600);
      expect(body.contains('on ArgumentError catch (e)'), isTrue,
          reason: '★ 必须单独接住 ArgumentError（它跟网络错误不是一回事）');
      expect(body.contains('没认出 BV 号 / av 号 / 链接：'), isTrue,
          reason: '★ 这句话要与 core 里的原话对得上（施工单 §9 第④条）');
      expect(body.contains('_biliFail('), isTrue);
    });

    test('③ 自动更新的闸门语义：开关默认开、间隔默认 30 且被夹到 5~1440', () {
      /*
       * ★ 这条守的是 `_biliAutoRefresh` 的**前置条件**：
       *   它第一行 `if (!shouldAutoUpdate(cid: cid)) return;` —— 如果
       *   闸门语义写反了（比如默认关），用户会觉得「自动更新没生效」。
       *   宿主侧那两处调用点（切集 / 集列表）在 ④ 里已经断言过。
       */
      expect(biliAutoUpdateEnabled(), isTrue, reason: '★ 默认必须是**开**');
      expect(biliAutoUpdateInterval(), defaultIntervalMinutes);
      expect(defaultIntervalMinutes, 30);
      setBiliAutoUpdateEnabled(false);
      expect(shouldAutoUpdate(cid: 12345), isFalse,
          reason: '★ 开关关了 ⇒ 一次都不该刷');
      setBiliAutoUpdateEnabled(true);
      setBiliAutoUpdateInterval(1);
      expect(biliAutoUpdateInterval(), 5, reason: '★ 下限 5 分钟');
      setBiliAutoUpdateInterval(99999);
      expect(biliAutoUpdateInterval(), 1440, reason: '★ 上限 24 小时');
      UiPrefs.set(BiliPrefs.intervalKey, '不是数字');
      expect(biliAutoUpdateInterval(), defaultIntervalMinutes,
          reason: '★ 坏偏好不该让自动更新停摆');
    });

    test('④ 失败后 loading 归位（否则按钮永远转圈）', () {
      final i0 = _page.indexOf('void _biliFail(String msg)');
      expect(i0, greaterThan(0));
      final body = _page.substring(i0, i0 + 600);
      expect(body.contains('loading: false,'), isTrue);
      expect(body.contains('error: DanmakuException(msg),'), isTrue,
          reason: '★ 面板的 _errorSection 读的就是 DanmakuException.message');
    });
  });
}