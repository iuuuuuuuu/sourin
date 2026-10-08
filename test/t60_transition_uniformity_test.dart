// ═══════════════════════════════════════════════════════════════════════
//  task-14 ⑨「动画不统一」—— 两条过渡链的**同源**守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 动画效果并没有统一,我点下面的底栏和设置页的二级页动画根本就不一样,需要修复
//
// # 这个 bug 当年为什么能潜伏这么久
//
// 两条链各写各的：时长**数值相同**但不是同一个真源，曲线**根本不是同一条**。
//
//   底栏链（lib/shell.dart 的 _KeepAliveTransitionState）
//     AnimationController(duration: Duration(milliseconds: 260),
//                         curve: Curves.easeOutCubic)
//   二级页链（lib/ui/widgets/page_transition_route.dart）
//     transitionDuration => Motion.base            (= 260ms)
//     MotionPrefs.curve(context, Motion.easeOut)   (= Cubic(0.22, 1, 0.36, 1))
//
// Curves.easeOutCubic 约等于 Cubic(0.215, 0.61, 0.355, 1) —— 与 Motion.easeOut
// 在 40ms 处**透明度差 0.156**（0.564 vs 0.408）⇒ 肉眼可见「两条链不一样」。
// ★ 而当时**没有任何测试**盯着「两条链用的是同一条曲线」这件事。
//
// # 本文件三层判据（由弱到强）
//
// ① 同源契约（静态）：两条链都必须**逐字**引用 Motion.base / Motion.easeOut，
//    且底栏那个类体里**不许**再出现任何 Curves 硬编码曲线。
// ② 区分度自检（数值）：Motion.easeOut 与 Curves.easeOutCubic 必须**可区分**
//    （40ms 处透明度差 > 0.05）。若哪天有人把两者改成一样，这条会红 ——
//    它在提醒「本守卫已失去区分能力」，而不是静默变成永真断言。
// ③ 行为等价（实测）：同一个 40ms 时刻，两条链的几何量必须**互相吻合**，
//    且都吻合 Motion.easeOut 的解析值。
//
// # 为什么采样点是 40ms
//
// 260ms 的动画里 40ms 是两条曲线的**最大分歧点**（位移差 4.0px、透明度差
// 0.156）；采样越晚分歧越小（180ms 时透明度只差 0.032）⇒ 40ms 判别力最强。
//
// # 跑法
//
//   powershell -File .probe/flutter_test_lock.ps1 -Paths 'test/t60_transition_uniformity_test.dart' -Agent t60
//
// ⚠️ 本仓铁律⑤：所有 contains 断言必须先 stripComments —— lib/shell.dart 的
//    注释里**刻意**引用了 Curves.easeOutCubic 来解释「改前是什么」，
//    不剥注释的话「不许出现」那条会被**注释**弄成假红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

/// 采样画布（与 keepalive_anim_test / t50c 同一尺寸，读数才可比）
const double kW = 1280.0;
const double kH = 800.0;

/// PageTransition.apply 的 slideRight 起始位移（源码里写的是 0.02 * dir）
const double kAmp = 0.02;

/// 采样时刻：两条曲线的最大分歧点
const int kAtMs = 40;

/// 相对**解析值**的容差（判别力余量：若退回旧曲线，透明度偏 0.156、位移偏 4.0px）
const double kOpTol = 0.03;
const double kDxTol = 1.5;

/// 两条链**互相**吻合的容差（同一条曲线，应当几乎逐位相同）
const double kOpTolCross = 0.02;
const double kDxTolCross = 1.0;

/// 二级页链里那一页的 key
const ValueKey<String> kRouteKey = ValueKey<String>('t60-route-page');

/// 剥掉 // 与 /* */ 注释（**保留字符串字面量**）—— 本仓铁律⑤
///
/// ⚠️ 不能直接用 grep/contains：lib/shell.dart 的注释里**刻意**引用了
///    Curves.easeOutCubic 来解释「改前是什么」，不剥注释会假红。
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

/// 底栏链的宿主 —— 与 test/keepalive_anim_test.dart 的 _appWith 同构
Widget _shellApp() {
  final theme = FTheme.neutral.dark.desktop;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, child) => FTheme(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: ShellPage(key: debugShellKey),
  );
}

/// 二级页链的宿主 —— 与 test/t50c_page_transition_route_test.dart 的 _app 同构
///
/// ⚠️ 必须 ThemeData(platform: TargetPlatform.windows)：flutter_tester 默认
///    android，不设平台就取不到 buildPageTransitionsTheme() 里 windows 那一项。
Widget _routeApp(GlobalKey<NavigatorState> nav) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: nav,
    theme: ThemeData(
      platform: TargetPlatform.windows,
      pageTransitionsTheme: buildPageTransitionsTheme(),
    ),
    home: const _PlainPage(),
  );
}

class _PlainPage extends StatelessWidget {
  const _PlainPage();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(
      child: ColoredBox(color: Color(0xFFFFFFFF)),
    );
  }
}

class _RoutePage extends StatelessWidget {
  const _RoutePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(
      child: ColoredBox(color: Color(0xFF101010)),
    );
  }
}

void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {/* 认领环境噪声（同 keepalive_anim_test） */}
}

/// 读**某一页自己的**过渡层几何量（位移 dx 像素 + 不透明度）
///
/// ★ 必须用 find.ancestor 限定到这一页：find.byType(SlideTransition) 会命中
///   框架内部大量同名 widget（见 test/keepalive_anim_test.dart 的长注释）。
({double dx, double opacity}) _geometryOf(
  WidgetTester tester,
  Type pageType,
  double width,
) {
  final page = find.byType(pageType, skipOffstage: false);
  if (page.evaluate().isEmpty) return (dx: 0, opacity: 1);

  final slide = find.ancestor(
    of: page,
    matching: find.byType(SlideTransition, skipOffstage: false),
  );
  final fade = find.ancestor(
    of: page,
    matching: find.byType(FadeTransition, skipOffstage: false),
  );

  var dx = 0.0;
  if (slide.evaluate().isNotEmpty) {
    dx = tester.widget<SlideTransition>(slide.first).position.value.dx * width;
  }
  var op = 1.0;
  if (fade.evaluate().isNotEmpty) {
    op = tester.widget<FadeTransition>(fade.first).opacity.value;
  }
  return (dx: dx, opacity: op);
}

/// 40ms 处 Motion.easeOut 的解析值（两条链都应当落在这里）
double get _wantOpacity => Motion.easeOut.transform(kAtMs / Motion.base.inMilliseconds);

/// 40ms 处 slideRight 的解析位移
double get _wantDx => kAmp * kW * (1.0 - _wantOpacity);

/// 两条链各自在 40ms 处的实测读数
///
/// ⚠️ 为什么用**顶层变量**而不是在同一个 testWidgets 里量两次：
///    ★ 试过了，行不通 —— 在同一个 test 里先 pumpWidget(壳) 再
///      pumpWidget(路由树)，**换树那一帧**会把刚 push 的路由连同它的
///      transition 层一起丢掉（实测 `fades=` / `slides=` 两个清单都是空的，
///      `_geometryOf` 退化成哨兵值 (dx:0, opacity:1)）。框架内部还会在
///      flushSemantics 时抛 `debugCheckForParentData` 断言。
///    ⇒ 改为**两个独立的 test 各量一条链**（各自一棵干净的树），把读数存进
///      这两个变量，再由第三个 test 比对。flutter test 在同一个文件里
///      **按声明顺序串行**跑测试，所以这样是可靠的。
({double dx, double opacity})? _shellAt40;
({double dx, double opacity})? _routeAt40;

void main() {
  group('① 同源契约（静态源码，剥注释后逐字比对）', () {
    late String shell;
    late String route;

    setUpAll(() {
      shell = stripComments(File('lib/shell.dart').readAsStringSync());
      route = stripComments(
        File('lib/ui/widgets/page_transition_route.dart').readAsStringSync(),
      );
    });

    test('底栏链：时长引 Motion.base、曲线引 Motion.easeOut（正向 + 反向都是）', () {
      expect(
        shell,
        contains('duration: Motion.base,'),
        reason: '★ 底栏链的 AnimationController 时长必须引 Motion.base —— '
            '写回 Duration(milliseconds: 260) 就是「数值相同但真源分裂」的老毛病',
      );
      final n = 'MotionPrefs.curve(context, Motion.easeOut)'.allMatches(shell).length;
      expect(
        n,
        greaterThanOrEqualTo(2),
        reason: '★ curve 与 reverseCurve 都必须引 Motion.easeOut'
            '（实测命中数应为 2，现在是 $n）',
      );
    });

    test('二级页链：时长引 Motion.base、曲线引 Motion.easeOut', () {
      expect(
        route,
        contains('_style == PageTransitionStyle.none ? Duration.zero : Motion.base;'),
        reason: '★ 二级页链的路由时长必须引 Motion.base（none 例外见 page_transition_route.dart 文件头）',
      );
      expect(
        route,
        contains('MotionPrefs.curve(context, Motion.easeOut)'),
        reason: '★ 二级页链的入场曲线必须是 Motion.easeOut',
      );
    });

    test('底栏链的类体里不许再出现硬编码 Curves 曲线', () {
      final start = shell.indexOf('class _KeepAliveTransitionState');
      expect(start, greaterThan(-1), reason: '找不到 _KeepAliveTransitionState（改名了？本测试要跟着改）');
      final end = shell.indexOf('\nclass ', start + 1);
      expect(end, greaterThan(start), reason: '找不到 _KeepAliveTransitionState 之后的第一个顶层 class');
      final body = shell.substring(start, end);
      expect(
        body,
        isNot(contains('Curves.')),
        reason: '★★ 底栏链的类体里出现了硬编码曲线（Curves.xxx）—— '
            '这正是用户报的「两条链动画不一样」的成因。'
            '要用曲线请引 Motion.easeOut（= Cubic(0.22, 1, 0.36, 1)）',
      );
    });

    test('底栏链的类体里确实用了 Motion.easeOut（防止上面那条靠删代码变绿）', () {
      final start = shell.indexOf('class _KeepAliveTransitionState');
      final end = shell.indexOf('\nclass ', start + 1);
      final body = shell.substring(start, end);
      expect(body, contains('MotionPrefs.curve(context, Motion.easeOut)'));
      expect(body, contains('duration: Motion.base,'));
    });
  });

  group('② 区分度自检（旧曲线必须与 Motion.easeOut 可区分）', () {
    test('Motion.easeOut 与 Curves.easeOutCubic 在 40/80/120ms 处差异 > 0.05', () {
      for (final ms in <int>[40, 80, 120]) {
        final t = ms / Motion.base.inMilliseconds;
        final a = Motion.easeOut.transform(t);
        final b = Curves.easeOutCubic.transform(t);
        // ignore: avoid_print
        print('T60|curve|t=${ms}ms|Motion.easeOut=${a.toStringAsFixed(6)}'
            '|Curves.easeOutCubic=${b.toStringAsFixed(6)}'
            '|diff=${(a - b).abs().toStringAsFixed(6)}');
        expect(
          (a - b).abs(),
          greaterThan(0.05),
          reason: '★ 两条曲线在 ${ms}ms 处只差 ${(a - b).abs().toStringAsFixed(4)}'
              ' —— 本守卫已失去区分能力（要么曲线被改成一样，要么采样点该换）',
        );
      }
    });

    test('Motion.easeOut 不是 Curves.easeOutCubic 的别名', () {
      expect(identical(Motion.easeOut, Curves.easeOutCubic), isFalse);
      expect(Motion.easeOut.transform(0.5), isNot(closeTo(Curves.easeOutCubic.transform(0.5), 0.001)));
    });
  });

  group('③ 行为等价（两条链在同一个 40ms 时刻的实测读数）', () {
    testWidgets('底栏链：home→live 后 40ms 的几何量 == Motion.easeOut 解析值', (tester) async {
      await tester.binding.setSurfaceSize(const Size(kW, kH));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideRight);

      await tester.pumpWidget(_shellApp());
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;
      shell.debugSwitchTo(AppTab.live); // home(0) → live(1)：dir = +1
      await tester.pump(); // 让 setState 生效，控制器从 0 开始（t = 0）
      await tester.pump(const Duration(milliseconds: kAtMs)); // t = 40ms
      _claim(tester);

      final g = _geometryOf(tester, LivePage, kW);
      _shellAt40 = g;
      final want = _wantOpacity;
      final wantDx = _wantDx;
      // ignore: avoid_print
      print('T60|shell|t=${kAtMs}ms|opacity=${g.opacity.toStringAsFixed(6)}'
          '|dx=${g.dx.toStringAsFixed(3)}'
          '|wantOpacity=${want.toStringAsFixed(6)}'
          '|wantDx=${wantDx.toStringAsFixed(3)}');

      expect(
        g.opacity,
        closeTo(want, kOpTol),
        reason: '★ 底栏链 40ms 处的不透明度应为 Motion.easeOut 的解析值 '
            '${want.toStringAsFixed(6)}（旧曲线 Curves.easeOutCubic 会是 '
            '${Curves.easeOutCubic.transform(kAtMs / Motion.base.inMilliseconds).toStringAsFixed(6)}）',
      );
      expect(g.dx, closeTo(wantDx, kDxTol),
          reason: '★ 底栏链 40ms 处的位移应为 ${wantDx.toStringAsFixed(3)}px');
    });

    testWidgets('二级页链：push 后 40ms 的几何量 == Motion.easeOut 解析值', (tester) async {
      await tester.binding.setSurfaceSize(const Size(kW, kH));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideRight);

      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_routeApp(nav));
      expect(find.byKey(kRouteKey), findsNothing, reason: '还没 push 就不该有详情页');

      final route = MaterialPageRoute<void>(builder: (_) => const _RoutePage(key: kRouteKey));
      nav.currentState!.push(route);

      // ★ 零点 = push 之后**第一次能被默认 finder 找到**的那一帧
      //   （HeroController 会先把新路由挂到离屏，见 t50c 文件头与 heroes.dart:967）
      await tester.pump();
      var off = 0;
      while (off < 6 && find.byKey(kRouteKey).evaluate().isEmpty) {
        await tester.pump();
        off++;
      }
      expect(off, lessThan(6), reason: 'push 之后 6 帧都找不到详情页');
      expect(find.byKey(kRouteKey), findsOneWidget);
      expect(
        route.animation!.value,
        0.0,
        reason: '零点必须还在动画起点（不带时长的 pump 不该推进假时钟）',
      );

      await tester.pump(const Duration(milliseconds: kAtMs)); // t = 40ms
      _claim(tester);

      final g = _geometryOf(tester, _RoutePage, kW);
      _routeAt40 = g;
      final want = _wantOpacity;
      final wantDx = _wantDx;
      // ignore: avoid_print
      print('T60|route|t=${kAtMs}ms|opacity=${g.opacity.toStringAsFixed(6)}'
          '|dx=${g.dx.toStringAsFixed(3)}'
          '|wantOpacity=${want.toStringAsFixed(6)}'
          '|wantDx=${wantDx.toStringAsFixed(3)}');

      expect(
        g.opacity,
        closeTo(want, kOpTol),
        reason: '★ 二级页链 40ms 处的不透明度应为 Motion.easeOut 的解析值 '
            '${want.toStringAsFixed(6)}',
      );
      expect(g.dx, closeTo(wantDx, kDxTol),
          reason: '★ 二级页链 40ms 处的位移应为 ${wantDx.toStringAsFixed(3)}px');
    });

    testWidgets('★★ 两条链在同一个 40ms 时刻的读数必须一致（这就是用户报的那条）', (tester) async {
      final gs = _shellAt40;
      final gr = _routeAt40;
      expect(gs, isNotNull,
          reason: '★ 上一条「底栏链」的 test 没跑成/没记读数 —— 本文件里测试按声明顺序串行，'
              '它必须在本条之前跑过。若你是单独 -N 跑的，请整文件跑。');
      expect(gr, isNotNull, reason: '★ 上一条「二级页链」的 test 没跑成/没记读数');
      final s = gs!;
      final rr = gr!;

      // ignore: avoid_print
      print('T60|cross|shell.opacity=${s.opacity.toStringAsFixed(6)}'
          '|route.opacity=${rr.opacity.toStringAsFixed(6)}'
          '|dop=${(s.opacity - rr.opacity).abs().toStringAsFixed(6)}'
          '|shell.dx=${s.dx.toStringAsFixed(3)}'
          '|route.dx=${rr.dx.toStringAsFixed(3)}'
          '|ddx=${(s.dx - rr.dx).abs().toStringAsFixed(3)}');

      expect(
        (s.opacity - rr.opacity).abs(),
        lessThan(kOpTolCross),
        reason: '★★ 两条链在 40ms 处的不透明度不一致 —— 这就是用户报的'
            '「我点下面的底栏和设置页的二级页动画根本就不一样」',
      );
      expect(
        (s.dx - rr.dx).abs(),
        lessThan(kDxTolCross),
        reason: '★★ 两条链在 40ms 处的位移不一致',
      );
    });
  });
}
