@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t103 —— ★★★ 桌面端第 1 条回归：弹幕报错要**可操作**（不是只有一句英文）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报（截图 u9_4bb447da.png）
// \`\`\`text
// 弹幕失败：Missing Authentication Headers
// \`\`\`
//
// 这句话是 dandanplay 的原话，**必须原样留着**（排错唯一线索），
// 但用户看完不知道要干什么。核心判断在 \`lib/core/danmaku.dart\` 的
// \`DanmakuHint.of\`（纯函数，由 t100 ⑤ 组钉住），本文件守的是
// **把它画出来**这一段：
//
//   ① 面板里出现中文指引（标题 + 怎么做 + 官方地址）
//   ② 那枚动作按钮点了真的把 \`DanmakuHintAction\` 递回宿主
//   ③ 宿主没接 \`onHintAction\` ⇒ 按钮不画（点了没反应更糟）
//   ④ hint == null（例如 HTTP 500）⇒ **一个字都不加**，只说服务端原文
//   ⑤ ★ 真棵树上：403 错误真的能从 \`_danmakuError\` 走到面板里
//
// # 关于夹具
// ④ 组（纯 widget）直接喂 \`DanmakuSettingsState\`，不发网络。
// ⑤ 组要起真 PlayerPage ⇒ 需要 libmpv（同 t98/t102），并且**必须**
// \`--run-skipped --tags native-media --concurrency=1\`（dart_test.yaml:62-69）。
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// ★★ 把 \`hint\` 挂上去 —— **生产就是这么造的**
///
/// \`DanmakuException\` 的构造器**不会**自己算 hint，是 \`_decode\`
/// （core/danmaku.dart）在造异常时调 \`DanmakuHint.of\` 挂上去的。
/// 这里逐字复刻那一步，否则测的是一条生产上不存在的路径。
///
/// ⚠️ 面板**故意不自己调** \`DanmakuHint.of\`：那个函数只认 401/403，
///   而 B 站链路（bili_api.dart 的 \`_getJson\`）也会抛 403 ——
///   同样是 403，一个该说"去填 dandanplay 凭证"，另一个说这句话就是**误导**。
///   所以「这一条错误该不该给指引」只能由造它的那一层回答。
DanmakuException withHint(DanmakuException e) => DanmakuException(
      e.message,
      statusCode: e.statusCode,
      xErrorMessage: e.xErrorMessage,
      errorCode: e.errorCode,
      errorMessage: e.errorMessage,
      body: e.body,
      uri: e.uri,
      hint: DanmakuHint.of(e),
    );

/// 无凭证访问 dandanplay 的**真实**响应组合（见 core/danmaku.dart:861-868）
DanmakuException noCredential() => withHint(DanmakuException(
      '弹幕接口返回 HTTP 403',
      statusCode: 403,
      xErrorMessage: 'Missing Authentication Headers',
    ));

/// 有凭证但没通过
DanmakuException badCredential() => withHint(DanmakuException(
      '弹幕接口返回 HTTP 403',
      statusCode: 403,
      xErrorMessage: 'Invalid Signature',
    ));

/// 判不出类别的那种失败（500）—— hint 必须是 null
DanmakuException serverError() => withHint(DanmakuException(
      '弹幕接口返回 HTTP 500',
      statusCode: 500,
    ));

DanmakuSettingsState settingsState(DanmakuException? e) =>
    DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 1.0,
      speed: 8.0,
      area: 1.0,
      error: e,
    );

class Calls {
  DanmakuHintAction? action;
}

/// 面板根节点是 \`Positioned.fill\` ⇒ 必须套 Stack（同 t73/t100）
Widget dialogHost(
  DanmakuSettingsState state,
  Calls c, {
  bool withAction = true,
}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            DanmakuSettingsDialog(
              state: state,
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
              onHintAction: withAction ? (DanmakuHintAction a) => c.action = a : null,
            ),
          ],
        ),
      ),
    );

Future<void> pumpDialog(
  WidgetTester t,
  DanmakuSettingsState state,
  Calls c, {
  bool withAction = true,
}) async {
  // 卡片 maxHeight 620 + 指引段落 ⇒ 默认 800x600 会把它挤出视口、点不到
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(dialogHost(state, c, withAction: withAction));
  await t.pump();
}

// ── 真树夹具（同 t98/t102）────────────────────────────────────────────

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep\$i', title: '第\$i集', url: 'https://example.invalid/\$i.m3u8'),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '弹幕提示回归',
        episodes: fakeEpisodes(5),
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

/// 剥 Dart 注释（字符串字面量里的斜杠不算注释）—— 同 t100
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  group('① 面板画出中文指引（纯 widget，不发网络）', () {
    testWidgets('★ 403 + Missing Authentication Headers ⇒ 标题/做法/地址都在，原文也留着',
        (t) async {
      final c = Calls();
      await pumpDialog(t, settingsState(noCredential()), c);

      expect(find.text('弹幕服务没收到凭证'), findsOneWidget,
          reason: '★ 这是用户唯一能看懂的那一句');
      expect(find.textContaining('去官网免费申请'), findsOneWidget,
          reason: '★ 光说"缺凭证"不够，得说去哪拿');
      expect(find.text('https://dev.dandanplay.com'), findsOneWidget);
      /*
       * ★ 原文不是独立的一个 Text —— 它在 e.detail 里
       *   （core/danmaku.dart 的 String get detail 拼成
       *    'HTTP 403\nX-Error-Message: Missing Authentication Headers'）
       *   ⇒ 必须 textContaining，精确匹配恒为 0。
       */
      expect(find.textContaining('Missing Authentication Headers'), findsWidgets,
          reason: '★★ 服务端原文一个字都不许丢（排错唯一线索）');
    });

    testWidgets('★ 403 + Invalid Signature ⇒ 是「凭证没通过」，不许说成没填', (t) async {
      final c = Calls();
      await pumpDialog(t, settingsState(badCredential()), c);

      expect(find.text('凭证没通过'), findsOneWidget);
      expect(find.text('弹幕服务没收到凭证'), findsNothing,
          reason: '★ 这两类必须分开：一个去申请，一个去检查复制粘贴');
      expect(find.textContaining('Invalid Signature'), findsWidgets);
    });

    testWidgets('★★ 判不出类别（HTTP 500）⇒ 一个字都不加，只说服务端原文', (t) async {
      final c = Calls();
      await pumpDialog(t, settingsState(serverError()), c);

      expect(find.text('弹幕服务没收到凭证'), findsNothing);
      expect(find.text('凭证没通过'), findsNothing);
      expect(find.text('拿到的是网页，不是数据'), findsNothing);
      expect(find.textContaining('去官网免费申请'), findsNothing,
          reason: '★ 猜错比不说更糟：会让用户去改一对本来没错的凭证');
      expect(find.text('弹幕接口返回 HTTP 500'), findsOneWidget);
    });
  });

  group('② 动作按钮', () {
    testWidgets('★ 点了把 DanmakuHintAction 原样递回宿主（面板不自己开关面板）',
        (t) async {
      final c = Calls();
      await pumpDialog(t, settingsState(noCredential()), c);

      final btn = find.widgetWithText(FilledButton, '去弹幕设置');
      expect(btn, findsOneWidget, reason: '★ 指引必须有一个能点的出口');
      /*
       * ★★ 必须先滚进视口
       *
       * 卡片 maxHeight 620，指引段落排在「服务端返回」上面 —— 面板内容
       * 一长，按钮就落在 SingleChildScrollView 的**可视区之外**（实测
       * y=1741 > 视口 1600）。此时 t.tap 会警告
       * "derived an Offset ... that would not hit test" 并**打空**，
       * 回调自然是 null —— 那是夹具没滚，不是按钮坏了。
       */
      await t.ensureVisible(btn);
      await t.pump();
      await t.tap(btn);
      await t.pump();

      final a = c.action;
      expect(a, isNotNull, reason: '★ 点了没回调 = 死按钮');
      expect(a!.label, '去弹幕设置');
      expect(a.openDanmakuSettings, isTrue);
      expect(a.openBiliSheet, isTrue,
          reason: '★ 缺凭证那条同时给两个出口：申请凭证 / 改用 B 站弹幕');
    });

    testWidgets('★★ 宿主没接 onHintAction ⇒ 按钮不画（指引文字照旧）', (t) async {
      final c = Calls();
      await pumpDialog(t, settingsState(noCredential()), c, withAction: false);

      expect(find.text('弹幕服务没收到凭证'), findsOneWidget,
          reason: '★ 文字不依赖回调，照旧要给');
      expect(find.text('去弹幕设置'), findsNothing,
          reason: '★★ 画了却没回调 = 用户点了没反应，比不画更糟');
      expect(c.action, isNull);
    });
  });

  group('③ 真棵树上：403 从 _danmakuError 走到面板里', () {
    testWidgets('★★★ 注入真实 403 错误 ⇒ 打开弹幕面板能看到中文指引', (t) async {
      await mountPlayer(t);
      expect(debugPlayerInjectDanmakuErrorForProbe(noCredential()), isTrue,
          reason: '★ 探针写的是真字段 _danmakuError');
      expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
      await t.pump();

      expect(find.text('弹幕服务没收到凭证'), findsOneWidget,
          reason: '★★★ 生产链路上必须真的画出来（探针 → _danmakuSettings.error → 面板）');
      expect(find.textContaining('Missing Authentication Headers'), findsWidgets);
      expect(find.widgetWithText(FilledButton, '去弹幕设置'), findsOneWidget,
          reason: '★ 宿主这一侧也接了 onHintAction');

      expect(debugPlayerCloseDanmakuSettingsForProbe(), isTrue);
      await drain(t);
    });
  });

  group('④ 第 2 条（B 站搜索）的宿主接线', () {
    /*
     * ★ 为什么这里只能静态审计
     *
     * \`_biliSearch\` 体内 \`await _ensureBiliApi().searchVideos(kw)\` 会**发真网络**
     * （BiliApi 的 HttpClient 不可从宿主注入）—— 单测里不许发。
     * 面板那一侧（渲染结果 / 点一条回传 bvid / 没接回调就不画按钮）
     * 已经由 \`test/t100_bili_search_test.dart\` ⑥ 组逐条钉住；
     * 这里只守"宿主把线接上了"。
     */
    test('★ 宿主把 onSearch 递给面板，且搜索不清空输入框里的链接', () {
      final src = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
      expect(src.contains('onSearch: _biliSearch,'), isTrue,
          reason: '★ 不接 ⇒ 面板的搜索区根本不显示（bili_import_dialog 的 '
              '\`if (widget.onSearch != null)\`）');
      expect(src.contains('Future<void> _biliSearch(String keyword) async'),
          isTrue);
      // 令牌守卫：面板是哪一集打开的，中途换集后回来的结果必须丢掉
      expect(src.contains('if (!mounted || token != _biliPanelToken) return;'),
          isTrue);
      expect(src.contains("busyLabel: '正在搜 B 站…'"), isTrue,
          reason: '★ 搜索是网络请求，必须告诉用户"在搜"');
    });

    test('★ 打开面板时清掉上一次的搜索结果，并把关键词预填成本集标题', () {
      final src = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
      final i = src.indexOf('void _openBiliSheet()');
      expect(i, greaterThan(-1));
      /*
       * ★ 3000 字符窗口已实测覆盖到 searchKeyword（动手前打印过
       *   body.length == 3000 且 body.contains('searchKeyword') == true）
       *   ⇒ 不扩大窗口。**不许**换成整文件 src.contains(...)：那会丢掉
       *   "这段代码确实在 _openBiliSheet 体内" 这层约束。
       */
      final body = src.substring(i, (i + 3000).clamp(0, src.length));
      // ① 上一次的搜索结果仍然必须清掉 —— 这条语义没变
      expect(body.contains('searchResults: const <BiliSearchItem>[],'), isTrue,
          reason: '★ 留着上一集的结果 ⇒ 用户点一条就绑到错的视频上');
      /*
       * ② 2026-10-09 起（Owner：「获取弹幕 bilibili和弹弹都应该支持
       *    自动填入名字」）关键词**不再是空串**，改成预填当前标题。
       *
       * ⚠️ 语义已经从「清空关键词」变成「预填关键词」——
       *    断言必须跟着语义走，钉住的是**预填**这件事本身。
       *    \`_biliSearch\` 里用户点搜索后的回写是 \`searchKeyword: kw,\`，
       *    与这里不冲突。
       */
      expect(body.contains('searchKeyword: _liveTitle.trim(),'), isTrue,
          reason: '★ 预填本集标题，用户不用每次手打一遍剧名');
      // ③ ★★ 反向断言：不许改回空串（改回去 = 搜索框又空了）
      expect(body.contains("searchKeyword: '',"), isFalse,
          reason: '★★ 改回空串就是退回"每次都要手打剧名"的老毛病');
    });
  });

  group('⑤ 静态审计（宿主接线不许被改回去）', () {
    test('★ player_page.dart：面板接了 onHintAction，宿主有执行器', () {
      final src = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync(),
      );
      expect(src.contains('onHintAction: _runDanmakuHintAction,'), isTrue);
      expect(src.contains('void _runDanmakuHintAction(DanmakuHintAction a)'),
          isTrue);
      expect(src.contains('final h = e.hint;'), isTrue,
          reason: '★ 提示条与角标都要带标题');
    });

    test('★ danmaku_settings_dialog.dart：回调可空 + 指引段落在面板里', () {
      final src = stripComments(
        File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync(),
      );
      expect(src.contains('this.onHintAction,'), isTrue);
      expect(src.contains('final ValueChanged<DanmakuHintAction>? onHintAction;'),
          isTrue);
      expect(src.contains('if (s.error?.hint != null)'), isTrue);
      expect(src.contains('Widget _hintSection(DanmakuHint h)'), isTrue);
      // ★ 面板是 UI 层，但**禁** import material.dart（全仓规矩，见 t99）
      expect(src.contains('package:flutter/material.dart'), isFalse);
    });
  });
}
