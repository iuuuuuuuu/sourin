// ═══════════════════════════════════════════════════════════════════════
//  桌面端第 4 条：「上次看到 …」文字超出面板被硬裁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，附 1444x845 截图）
//
// > 然后左侧的上次看到，文字也超出了
//
// 截图里那颗 chip 是：
// ```text
// 🕘 上次看到 啊啊7月新番你到底给我下了什么药啊！！【泛式】·
//                                                        ↑ 右边缘硬裁
// ```
// —— 注意**没有省略号**，是「切断」。
//
// # 根因（改前）
//
// `resumeLabel` 来自 `_fmtResume`，它拼的是**整条视频标题**
// （B 站投稿标题动辄 30+ 字）；而那颗 chip 的 `Row` 是
// `MainAxisSize.min`，两个 `Text` 都没有 `Flexible`/`maxLines`/
// `overflow` ⇒ 文本按自身固有宽度铺开，超出面板右边界被硬裁。
//
// # 修法
//
// ① 把 `_fmtResume` 拆成 `_resumeTitle` + `_resumeRemaining` 两半 ——
//    整串套 `Flexible` 也能止住溢出，但截断点在**串尾** ⇒ 先没的是
//    「剩 N 分钟」，而那才是这条提示里唯一会变、且用户真要读的信息。
// ② 标题那半套 `Flexible` + `maxLines: 1` + `ellipsis`。
// ③ 时间那半独立成一段，**不参与压缩**。
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ 本文件的尺子：`RenderParagraph.didExceedMaxLines` + 真渲染异常
// ══════════════════════════════════════════════════════════════════════
//
// 只断言"源码里有 Flexible"是**不够**的 —— 本仓铁律⑲：
// 断言结构/契约，不要断言符号存在。所以这里挂**真 DetailPage**、
// 注入**真 Progress**、跑**真 _buildBody**，量三个读数：
// ```text
// ① 可用宽 avail / 固有需要宽 need  → 证明"确实超了"（否则测试假绿）
// ② didExceedMaxLines              → 证明"真的走了省略号分支"
// ③ RenderFlex overflowed 异常      → 证明"没有硬裁"
// ```
// ★ 读数必须**一起报**：只看 ② 无法区分"截断正确"与"根本没量到"。
//
// 跑法（本文件不需要 native-media，纯 widget 测试）：
//   & "C:\Users\iuuuuuu\flutter\bin\flutter.bat" test \
//       test\t97_resume_chip_fit_test.dart --reporter expanded

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';

/// 剥注释（本仓铁律⑤：`contains` 必须先剥注释）
///
/// ★ 逐字节复用 `t64_panel_fixed_test.dart` 的状态机 —— 不自己写正则版
///   （正则版会把字符串里的 `//` 当注释，本仓已有教训）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
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

/// ★ Owner 截图里那颗 chip 的真实标题（B 站投稿标题，30+ 字）
const _longTitle = '啊啊7月新番你到底给我下了什么药啊！！【泛式】';

/// Owner 截图（1444x845）下右侧面板的真实宽度
///
/// 依据 `lib/ui/media_page.dart` 的 `detailW = (mq.size.width * 0.30).clamp(340.0, 440.0)`：
/// `1444 * 0.30 = 433.2` ⇒ 取 **433**。
/// ⚠️ 用真实宽度而不是随便挑一个 —— 缺陷只在"标题比面板宽"时现形。
const _panelW = 433.0;

MediaDetail _detail() => MediaDetail(
      id: 'cycani:t97',
      title: '无职转生',
      description: '简介',
      kind: 'series',
      episodes: const [
        Episode(id: 'ep-1', title: '第01集'),
        Episode(id: 'ep-2', title: '第02集'),
      ],
    );

/// 真主题 + 定宽面板里挂 `DetailPage`（`embedded: true` = 合并页右侧面板）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildMaterialTheme(theme),
    builder: (_, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 在**捕获窗口**内执行 [body]：把渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 为什么必须从 `FlutterError.onError` 取正文：同一个 pump 里抛出**多条**时，
///   `takeException()` 只给一句 "Multiple exceptions (2) were detected…"
///   —— 正文全丢，而我们要断言的恰恰是正文里的 `overflowed by N pixels`。
///   （这套 `_guard` 抄自 `test/t486_edge_row_label_fit_test.dart:62-76`。）
Future<void> _guard(List<String> sink, Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    sink.add(details.exceptionAsString().split('\n').first);
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

Future<void> _pumpDrain(WidgetTester t, int frames, List<String> sink) =>
    _guard(sink, () async {
      for (var i = 0; i < frames; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
    });

/// 溢出类异常（`RenderFlex overflowed by N pixels`）
List<String> _overflows(List<String> caught) =>
    caught.where((e) => e.contains('overflowed')).toList();

void _reportCaught(String tag, List<String> caught) {
  if (caught.isEmpty) {
    // ignore: avoid_print
    print('T97|$tag 捕获异常 0 条');
    return;
  }
  // ignore: avoid_print
  print('T97|$tag 捕获异常 ${caught.length} 条：');
  for (final e in caught) {
    // ignore: avoid_print
    print('T97|    $e');
  }
}

/// 挂载 + 注入详情与续播进度，返回 state
Future<GlobalKey<State<DetailPage>>> _mount(
  WidgetTester t,
  List<String> sink, {
  required double panelW,
  required String episodeTitle,
  int position = 120,
  int duration = 1500,
}) async {
  await t.binding.setSurfaceSize(Size(panelW, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<State<DetailPage>>();
  await _guard(sink, () async {
    await t.pumpWidget(_host(
      Scaffold(
        body: DetailPage(
          key: key,
          provider: 'cycani',
          id: 't97',
          embedded: true,
        ),
      ),
    ));
  });
  await _pumpDrain(t, 1, sink);

  final d = _detail();
  final st = key.currentState!;
  // ignore: avoid_dynamic_calls
  (st as dynamic).debugSetDetail(d, episodes: d.episodes);
  await _pumpDrain(t, 1, sink);
  // ignore: avoid_dynamic_calls
  (st as dynamic).debugSetResume(Progress(
    key: 'cycani:t97',
    provider: 'cycani',
    nativeId: 't97',
    title: '无职转生',
    episodeId: 'ep-1',
    episodeTitle: episodeTitle,
    position: position,
    duration: duration,
  ));
  await _pumpDrain(t, 3, sink);
  return key;
}

void main() {
  late String src;

  setUpAll(() {
    src = stripComments(File('lib/ui/detail_page.dart').readAsStringSync());
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检 —— 先证明这把尺子能区分"超了/没超"
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检（防假绿）', () {
    testWidgets('★ 短标题下，chip 的固有宽度必须**小于**可用宽（否则本文件恒红）',
        (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: '第01集');
      _reportCaught('自检-短标题', caught);

      final f = find.text(' · 剩 23 分钟');
      expect(f, findsOneWidget,
          reason: '★★ 时间那半必须原样渲染（短标题下不该有任何截断）—— '
              '找不到它说明 chip 的**结构**跟测试假设不一致，'
              '此时后面所有断言都无意义');

      final rp = t.renderObject<RenderParagraph>(f);
      final need = rp.getMaxIntrinsicWidth(double.infinity);
      // ignore: avoid_print
      print('T97|自检-短标题 avail=${rp.constraints.maxWidth.toStringAsFixed(1)} '
          'need=${need.toStringAsFixed(1)} '
          '${rp.didExceedMaxLines ? "CLIPPED" : "fits"}');
      expect(rp.didExceedMaxLines, isFalse,
          reason: '★ 短标题（「第01集」）不该被截断');
    });

    testWidgets('★★ 长标题下，chip **确实**超出可用宽（证明缺陷触发条件成立）',
        (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: _longTitle);
      _reportCaught('自检-长标题', caught);

      final f = find.text(' · 剩 23 分钟');
      expect(f, findsOneWidget);
      final rp = t.renderObject<RenderParagraph>(f);
      final need = rp.getMaxIntrinsicWidth(double.infinity);
      // ignore: avoid_print
      print('T97|自检-长标题 avail=${rp.constraints.maxWidth.toStringAsFixed(1)} '
          'need=${need.toStringAsFixed(1)} '
          '${rp.didExceedMaxLines ? "CLIPPED" : "fits"}');

      // ★ 这一条是"缺陷触发条件"的证明：标题的固有宽度必须大于面板宽
      final tf = find.text(_longTitle);
      expect(tf, findsOneWidget);
      final trp = t.renderObject<RenderParagraph>(tf);
      final tneed = trp.getMaxIntrinsicWidth(double.infinity);
      // ignore: avoid_print
      print('T97|自检-长标题 title avail=${trp.constraints.maxWidth.toStringAsFixed(1)} '
          'need=${tneed.toStringAsFixed(1)} '
          '${trp.didExceedMaxLines ? "CLIPPED" : "fits"}');
      expect(tneed, greaterThan(trp.constraints.maxWidth),
          reason: '★★ 触发条件：标题固有宽（${tneed.toStringAsFixed(1)}）'
              '必须大于可用宽（${trp.constraints.maxWidth.toStringAsFixed(1)}），'
              '否则本文件测不到缺陷 —— 这本身就是防假绿的断言');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 缺陷本体：长标题下不许有 RenderFlex 溢出，且时间必须完整
  // ═══════════════════════════════════════════════════════════════════

  group('① 桌面端第 4 条：长标题下 chip 不溢出、时间不被吃掉', () {
    testWidgets('★★★ 面板 433px + 30+ 字标题 ⇒ 零 RenderFlex 溢出', (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: _longTitle);
      _reportCaught('① 长标题', caught);

      final ovf = _overflows(caught);
      expect(ovf, isEmpty,
          reason: '★★★ 改前这里会报 '
              '`A RenderFlex overflowed by N pixels on the right.` '
              '（Owner 截图里那颗 chip 被右边缘硬裁就是它）—— 实测 $ovf');
    });

    testWidgets('★★★ 时间那半（「剩 N 分钟」）必须**完整**显示，不许被省略号吃掉',
        (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: _longTitle);
      _reportCaught('① 时间完整', caught);

      final f = find.text(' · 剩 23 分钟');
      expect(f, findsOneWidget,
          reason: '★★★ 这是本条修复的**核心契约**：整串套 Flexible 也能止住'
              '溢出，但截断点在串尾 ⇒ 先没的是「剩 N 分钟」。'
              '现在时间独立成一段 ⇒ 无论标题多长它都必须完整。');

      /*
       * ★★ 真正强的判据是这一条，不是 didExceedMaxLines：
       *   一个**没有** maxLines 的 Text，didExceedMaxLines 恒为 false
       *   ⇒ 光看它无法区分「时间没被压缩」与「时间根本没量到」。
       *   而「时间有没有参与压缩」在树上是**可判定**的：它外面
       *   有没有 `Flexible`/`Expanded` 祖先。
       *   ⚠️ 若将来有人图省事把时间那半也塞进 Flexible，
       *      didExceedMaxLines 那条**照样绿**，只有这条会红。
       */
      expect(
        find.ancestor(of: f, matching: find.byType(Flexible)),
        findsNothing,
        reason: '★★★ 「剩 N 分钟」**不许**有 Flexible 祖先 —— '
            '它一旦参与压缩，长标题下先没的还是它（缺陷原样复现）',
      );
      expect(
        find.ancestor(of: f, matching: find.byType(Expanded)),
        findsNothing,
        reason: '★★★ 同上（Expanded 是 Flexible 的子类，一并钉住）',
      );

      final rp = t.renderObject<RenderParagraph>(f);
      expect(rp.didExceedMaxLines, isFalse,
          reason: '★★★ 「剩 23 分钟」自己被截断了 —— '
              '说明它仍然跟标题挤在同一段里（修法没生效）');
      expect(rp.size.width, greaterThanOrEqualTo(139.0),
          reason: '★★ 时间那半的**渲染宽**必须接近它的固有宽（140）—— '
              '被压窄过就说明它参与了压缩');
    });

    testWidgets('★★ 标题那半必须真的走了省略号分支（不是被硬裁）', (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: _longTitle);
      _reportCaught('① 标题省略', caught);

      final tf = find.text(_longTitle);
      expect(tf, findsOneWidget);
      final trp = t.renderObject<RenderParagraph>(tf);
      // ignore: avoid_print
      print('T97|① 标题 didExceedMaxLines=${trp.didExceedMaxLines} '
          'overflow=${trp.overflow}');
      expect(trp.didExceedMaxLines, isTrue,
          reason: '★★ 长标题必须走省略号分支（didExceedMaxLines = true）—— '
              'false 说明它还在按固有宽度铺开（= 硬裁）');
      expect(trp.overflow, TextOverflow.ellipsis,
          reason: '★ 必须是 ellipsis，不是 clip/fade');
    });

    testWidgets('★ 前缀「上次看到 」必须完整（固定文案不许被压缩）', (t) async {
      final caught = <String>[];
      await _mount(t, caught, panelW: _panelW, episodeTitle: _longTitle);
      _reportCaught('① 前缀', caught);

      final f = find.text('上次看到 ');
      expect(f, findsOneWidget,
          reason: '★★ 既有门禁 test/detail_follow_test.dart:538 也钉着这串字面量');
      final rp = t.renderObject<RenderParagraph>(f);
      expect(rp.didExceedMaxLines, isFalse,
          reason: '★★ 「上次看到 」是固定文案，被压缩会出现「上…」，'
              '信息反而丢了 —— 它**不该**参与 Flexible');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 静态契约：结构不许被改回去
  // ═══════════════════════════════════════════════════════════════════

  group('② 静态审计（剥注释后）', () {
    test('★★★ 续播 chip 必须保留三件套：Flexible + maxLines: 1 + ellipsis', () {
      final i = src.indexOf("'上次看到 '");
      expect(i, greaterThan(0),
          reason: '★★★ 找不到续播 chip 的锚点 —— 布局结构变了，'
              '本测试需要跟着更新（不要直接删断言）');

      // ★ 只取 chip 那一段（到 _Chip 类之前），避免命中别处的 Flexible
      final end = src.indexOf('class _Chip', i);
      final chip = src.substring(i, end > i ? end : i + 3000);
      // ignore: avoid_print
      print('T97|② chip 片段长度=${chip.length}');

      expect(chip.contains('Flexible('), isTrue,
          reason: '★★★ 标题那半必须套 Flexible，否则长标题又会被硬裁');
      expect(chip.contains('maxLines: 1'), isTrue,
          reason: '★★ 必须单行');
      expect(chip.contains('overflow: TextOverflow.ellipsis'), isTrue,
          reason: '★★ 必须省略号，不是 clip');
      expect(chip.contains('resumeTitle'), isTrue,
          reason: '★ 标题那半用 resumeTitle');
      expect(chip.contains('resumeRemaining'), isTrue,
          reason: '★ 时间那半用 resumeRemaining（独立成段 ⇒ 不参与压缩）');
    });

    test('★★ _fmtResume 那个"整串"写法不许回来', () {
      expect(src.contains('_fmtResume'), isFalse,
          reason: '★★★ 整串「标题 · 剩 N 分钟」是缺陷的**根因形态**：'
              '截断点落在串尾 ⇒ 先没的是时间。'
              '它已拆成 _resumeTitle + _resumeRemaining，不许并存');
    });

    test('★ 时间那半的字面量仍在（沿用原版 DetailView.vue:542-546 语义）', () {
      expect(src.contains(r"'剩 ${left ~/ 60} 分钟'"), isTrue,
          reason: '★ 剩余时间文案不改（原版逐字一致）');
      expect(src.contains(r"p.episodeTitle ?? '单集'"), isTrue,
          reason: '★ 标题兜底判据不改（原版 episode_title || "单集"）');
    });
  });
}
