/*
 * task-50 · 候选 2（`SourinPageTransitionsBuilder`）的 widget 测试
 *
 * # 这个测试要证的东西
 * Lead 的判据：「用户选的风格**真的生效**」——
 *   同一页（同一个 `_Page(key: kPageKey)`）上，换风格必须换出入场读数。
 *
 * # 三件仪器（都不手写 `AnimationController`）
 * A. 时长：`route.transitionDuration`（公开 API）+ 驱动画面的那个 `AnimationController`。
 *    ★ `route.animation` 返回的是 `_animationProxy`，即 `ProxyAnimation`
 *      （`routes.dart:1969-1970`；它在 `routes.dart:1685` 被建成
 *      `_animationProxy = ProxyAnimation(super.animation);`）。
 *      真正的控制器在它的 `.parent` 上：
 *      `routes.dart:250 return _controller!.view;` + `AnimationController.view => this`
 *      ⇒ 必须**先脱一层 `ProxyAnimation`** 才能读到它被写进去的时长。
 *      （第一版没脱，所以 `ctrlMs` 永远是 -2 哨兵值：实测失败断言
 *       `t50c_page_transition_route_test.dart:273 Expected: <0> Actual: <-2>`。）
 * B. 位移：`renderObject<RenderBox>(byKey(kPageKey)).localToGlobal(Offset.zero)`。
 *    ⇒ `SlideTransition` 的位移进渲染树（`RenderFractionalTranslation.applyPaintTransform`），
 *      所以"入场时偏了多少"可读。
 *      零点 = push 后**第一帧**（ticker 首帧 elapsed = 0）；终点 = pump(400ms) 之后；
 *      读数是 `零点 − 终点`（抵消掉路由自身的固定偏移）。
 * C. 结构：`find.ancestor(of: byKey(kPageKey), matching: byType(...))`。
 *    ⇒ `zoom` 走 SDK 的 `SnapshotWidget` 快照路径；其余风格走本项目的 widget 层。
 *
 * # Reduce Motion（用户判据 ④）
 * `disableAnimations=true` 时 `MotionPrefs.resolvedCurrent()` 返回 `none`
 * ⇒ `buildTransitions` 直接 `return child` ⇒ 几何/结构读数必须与 `none` **逐位相同**。
 * ★ 已知取舍（记录在 `lib/ui/widgets/page_transition_route.dart` 文件头）：
 *   `transitionDuration` 拿不到 `BuildContext` ⇒ 画面瞬间切换，但路由仍记账 260ms。
 *   本测试**如实记录** `routeMs`，不对它做"必须为 0"的断言。
 *
 * # 为什么必须 `ThemeData(platform: TargetPlatform.windows)`
 * `flutter_tester` 的默认平台是 `android` ⇒ 不设平台就取不到 `buildPageTransitionsTheme()`
 * 里 windows 那一项。**不能**用 `debugDefaultTargetPlatformOverride`：flutter_test 在
 * 测试结束时校验 foundation 调试变量，而 `addTearDown` 跑在校验**之后** ⇒ 必报
 * `The value of a foundation debug variable was changed by the test.`
 * （同 `test/transition_clip_titlebar_test.dart:95-103` 的既有结论）
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';
import 'package:sourin_spike/ui/widgets/page_transition_route.dart';

/// 被测文件（红度证明按这个路径改 / 还原）
const String kRouteSrc = 'lib/ui/widgets/page_transition_route.dart';

/// 被测的那一页 —— ★ 每个风格都用**同一个** key + 同一个 widget（=「同一页」）
const ValueKey<String> kPageKey = ValueKey<String>('t50c-route-page');

final File _log = File('.probe/t50c_route_points.txt');

void _rec(String line) {
  // ignore: avoid_print
  print(line);
  _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 路由内容：白底 + 文字，撑满屏幕（几何仪器要有确定的尺寸）
class _Page extends StatelessWidget {
  const _Page({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Center(child: Text(label)),
      ),
    );
  }
}

/// 和 `lib/ui/app_theme.dart` 里一致的接线：windows / linux 用本项目的 builder
Widget _app({
  required GlobalKey<NavigatorState> navigatorKey,
  required bool reduceMotion,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: navigatorKey,
    theme: ThemeData(
      platform: TargetPlatform.windows,
      pageTransitionsTheme: buildPageTransitionsTheme(),
    ),
    // `MaterialApp.builder` 在 Navigator **之上** ⇒ 路由的 context 看得到这个 MediaQuery
    builder: (BuildContext ctx, Widget? child) {
      final MediaQueryData base =
          MediaQuery.maybeOf(ctx) ?? const MediaQueryData();
      return MediaQuery(
        data: base.copyWith(disableAnimations: reduceMotion),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: const _Page(label: '首页'),
  );
}

class _Reading {
  _Reading({
    required this.style,
    required this.reduceMotion,
    required this.offstageFrames,
    required this.routeMs,
    required this.controllerMs,
    required this.delta,
    required this.completedMs,
    required this.slideN,
    required this.scaleN,
    required this.snapN,
  });

  final PageTransitionStyle style;
  final bool reduceMotion;
  final int routeMs;
  final int controllerMs;
  final int offstageFrames;
  final Offset delta;
  final int completedMs;
  final int slideN;
  final int scaleN;
  final int snapN;

  String get line => 'T50C|style=${style.name}|reduce=$reduceMotion'
      '|routeMs=$routeMs|ctrlMs=$controllerMs'
      '|dx=${delta.dx.toStringAsFixed(4)}|dy=${delta.dy.toStringAsFixed(4)}'
      '|doneMs=$completedMs|slide=$slideN|scale=$scaleN|snap=$snapN'
      '|offFrames=$offstageFrames';
}

Future<_Reading> _measure(
  WidgetTester t, {
  required PageTransitionStyle style,
  required bool reduceMotion,
}) async {
  PageTransitionStyleStore.resetForTest(style);

  final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(_app(navigatorKey: nav, reduceMotion: reduceMotion));
  expect(find.byKey(kPageKey), findsNothing, reason: '还没 push 就不该有详情页');

  final MaterialPageRoute<void> route = MaterialPageRoute<void>(
    builder: (_) => const _Page(key: kPageKey, label: '详情'),
  );
  nav.currentState!.push(route);

  final Animation<double>? anim = route.animation;
  expect(anim, isNotNull, reason: 'TransitionRoute.animation 应已由 install() 建好');
  final int routeMs = route.transitionDuration.inMilliseconds;
  // ★ 控制器的时长**不能在这里读**：离屏期间 `_animationProxy.parent` 被换成了
  // `kAlwaysCompleteAnimation`，读到的不是控制器。详见零点之后的说明。

  // ★ 零点 = push 之后**第一次能被默认 finder 找到**的那一帧。
  //
  // 不能假设它就是 push 后的第一帧：`HeroController.startTransition`
  // （`flutter/lib/src/widgets/heroes.dart:967`）会先把新路由挂到离屏：
  //     `toRoute.offstage = toRoute.animation!.value == 0.0;`
  // 好在这一帧里量出英雄的落点，下一帧才在 `_startHeroTransition`
  // （同文件 L987 `to.offstage = false;`）把它放回台上。
  // `find.byKey` 默认 `skipOffstage: true`，过滤点就在
  // `_OffstageElement.debugVisitOnstageChildren`（`basic.dart:3664`）。
  // 探针实测（`.probe/t50c_probe1.txt`）：动画风格第一帧
  // `default=0 / skipOffstage:false=1 / offstageTrue=1`，第二帧才 `default=1`。
  //
  // 为什么“轮询”是安全的：不带时长的 `pump()` **不推进假时钟**，
  // 轮询多少次 ticker 的 elapsed 都还是 0 ⇒ `anim.value` 仍是 0.0。
  // 所以零点是**找到的**，不是猜的；下面 `anim.value == 0.0` 就是这件事的证据。
  // 第一次 pump 是**首次 build 帧**（此刻 push 后一帧都还没画过），
  // 不能算进离屏帧：它对 `none` 也必然发生。所以先单独 pump 它，
  // 再从 0 开始数"还要多少帧才找得到"。
  await t.pump();
  int offstageFrames = 0;
  while (offstageFrames < 6 && find.byKey(kPageKey).evaluate().isEmpty) {
    await t.pump();
    offstageFrames++;
  }
  expect(offstageFrames, lessThan(6),
      reason: 'push 之后 6 帧都找不到详情页（离屏帧过多，可能是真的没上屏）');
  expect(find.byKey(kPageKey), findsOneWidget);
  if (routeMs > 0) {
    expect(anim!.value, 0.0,
        reason: '零点必须还在动画起点：不带时长的 pump 不该推进假时钟');
  }

  // ★★ 控制器的时长必须在**离屏帧结束之后**读，这是本测试踩过的第二个坑：
  // 离屏期间 `set offstage`（`routes.dart:1958`）把
  // `_animationProxy.parent` 换成了 `kAlwaysCompleteAnimation`：
  //     `_animationProxy!.parent = _offstage ? kAlwaysCompleteAnimation : super.animation;`
  // 所以在 `push()` 之后立刻读，拿到的是 `_AlwaysCompleteAnimation`，
  // 不是那个 `AnimationController`（run4 实测：`Expected: <Instance of
  // 'AnimationController'> / Actual: _AlwaysCompleteAnimation`）。
  // `_startHeroTransition`（`heroes.dart:987`）把 `to.offstage = false` 之后
  // parent 才还原成 `super.animation`（= `_controller.view`，而 `view` 就是
  // 控制器自己，`animation_controller.dart:321`）⇒ 此刻脱一层才有意义。
  // 脱一层后必须是控制器，否则 `controllerMs` 会退化成 -2 这种哨兵值。
  final Animation<double>? raw = anim is ProxyAnimation ? anim.parent : anim;
  expect(raw, isA<AnimationController>(),
      reason: '离屏帧结束后，route.animation 脱一层 ProxyAnimation 应当就是控制器');
  final int controllerMs =
      raw is AnimationController ? (raw.duration?.inMilliseconds ?? -1) : -2;

  final RenderBox box = t.renderObject<RenderBox>(find.byKey(kPageKey));
  final Offset atZero = box.localToGlobal(Offset.zero);

  final int slideN = t
      .widgetList(find.ancestor(
        of: find.byKey(kPageKey),
        matching: find.byType(SlideTransition),
      ))
      .length;
  final int scaleN = t
      .widgetList(find.ancestor(
        of: find.byKey(kPageKey),
        matching: find.byType(ScaleTransition),
      ))
      .length;
  final int snapN = t
      .widgetList(find.ancestor(
        of: find.byKey(kPageKey),
        matching: find.byType(SnapshotWidget),
      ))
      .length;

  // 走到"动画完成"：10ms 一步，记录**第一次** isCompleted 为真的时刻
  int completedMs = 0;
  if (!anim!.isCompleted) {
    completedMs = -1;
    for (int i = 0; i < 80; i++) {
      await t.pump(const Duration(milliseconds: 10));
      if (anim.isCompleted) {
        completedMs = (i + 1) * 10;
        break;
      }
    }
  }

  await t.pump(const Duration(milliseconds: 400));
  final Offset atEnd = t
      .renderObject<RenderBox>(find.byKey(kPageKey))
      .localToGlobal(Offset.zero);

  return _Reading(
    style: style,
    reduceMotion: reduceMotion,
    routeMs: routeMs,
    controllerMs: controllerMs,
    delta: atZero - atEnd,
    completedMs: completedMs,
    offstageFrames: offstageFrames,
    slideN: slideN,
    scaleN: scaleN,
    snapN: snapN,
  );
}

void _mount(WidgetTester t) {
  t.view.physicalSize = const Size(1280, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  addTearDown(() =>
      PageTransitionStyleStore.resetForTest(PageTransitionStyleStore.defaultStyle));
}

void main() {
  testWidgets('接线：windows/linux 的 builder 就是 SourinPageTransitionsBuilder', (
    WidgetTester t,
  ) async {
    final PageTransitionsTheme theme = buildPageTransitionsTheme();
    expect(theme.builders[TargetPlatform.windows],
        isA<SourinPageTransitionsBuilder>());
    expect(theme.builders[TargetPlatform.linux],
        isA<SourinPageTransitionsBuilder>());
    _rec('T50C|wired=windows:${theme.builders[TargetPlatform.windows].runtimeType}'
        ',linux:${theme.builders[TargetPlatform.linux].runtimeType}');
  });

  testWidgets('同一页上，用户选的风格真的改变入场读数（时长 + 位移 + 结构）', (
    WidgetTester t,
  ) async {
    _mount(t);

    final Map<PageTransitionStyle, _Reading> rs = <PageTransitionStyle, _Reading>{};
    for (final PageTransitionStyle s in PageTransitionStyle.values) {
      final _Reading r = await _measure(t, style: s, reduceMotion: false);
      rs[s] = r;
      _rec(r.line);
    }

    // ① 时长真的进了路由 / 进了驱动画面的那个控制器
    expect(rs[PageTransitionStyle.none]!.routeMs, 0,
        reason: 'none 必须是"零时长"（真·无动画）');
    expect(rs[PageTransitionStyle.none]!.controllerMs, 0);
    expect(rs[PageTransitionStyle.none]!.completedMs, 0,
        reason: 'none 在第一帧就该已经完成');
    expect(rs[PageTransitionStyle.none]!.offstageFrames, 0,
        reason: 'none 时长 0 ⇒ 首帧即 completed ⇒ '
            'HeroController 不会把新路由挂到离屏 '
            '⇒ 首次 build 帧就找得到');

    for (final PageTransitionStyle s in PageTransitionStyle.values) {
      if (s == PageTransitionStyle.none) continue;
      final _Reading r = rs[s]!;
      expect(r.routeMs, Motion.base.inMilliseconds,
          reason: '风格 ${s.name} 的时长没送进路由（应 = Motion.base）');
      expect(r.controllerMs, Motion.base.inMilliseconds,
          reason: '风格 ${s.name} 的时长没进 AnimationController');
      expect(r.completedMs, inInclusiveRange(Motion.base.inMilliseconds, Motion.base.inMilliseconds + 40),
          reason: '风格 ${s.name} 实测完成时刻应在 Motion.base 附近');
      expect(r.offstageFrames, greaterThanOrEqualTo(1),
          reason: '风格 ${s.name} 应经历 SDK 的 Hero 离屏帧：'
              'heroes.dart:967 把 animation.value == 0 的新路由先挂到离屏');
    }

    // 只有"滑动类"风格在渲染树里留下位移（fade / zoom 只动透明度与画布）
    for (final PageTransitionStyle s in <PageTransitionStyle>[
      PageTransitionStyle.slideRight,
      PageTransitionStyle.slideUp,
      PageTransitionStyle.fadeUp,
    ]) {
      expect(rs[s]!.delta, isNot(Offset.zero),
          reason: '风格 ${s.name} 入场时应该有位移');
    }
    expect(rs[PageTransitionStyle.zoom]!.delta, Offset.zero,
        reason: 'zoom 的缩放只发生在快照画布上（RenderSnapshotWidget 无 applyPaintTransform）');

    // ② 几何：三个滑动风格各偏各的（同一页、同一尺寸 1280×800）
    expect(rs[PageTransitionStyle.slideRight]!.delta.dx, closeTo(25.6, 0.5),
        reason: 'slideRight 入场时应右偏 0.02 × 1280');
    expect(rs[PageTransitionStyle.slideRight]!.delta.dy.abs(), lessThan(0.01));
    expect(rs[PageTransitionStyle.slideUp]!.delta.dy, closeTo(48.0, 0.5),
        reason: 'slideUp 入场时应下偏 0.06 × 800');
    expect(rs[PageTransitionStyle.slideUp]!.delta.dx.abs(), lessThan(0.01));
    expect(rs[PageTransitionStyle.fadeUp]!.delta.dy, closeTo(16.0, 0.5),
        reason: 'fadeUp 入场时应下偏 0.02 × 800');
    expect(rs[PageTransitionStyle.fadeUp]!.delta.dx.abs(), lessThan(0.01));
    expect(rs[PageTransitionStyle.fade]!.delta, Offset.zero,
        reason: 'fade 不该有位移（只改透明度）');

    // ③ 结构：zoom 走 SDK 快照路径，其余风格走本项目 widget 层
    expect(rs[PageTransitionStyle.zoom]!.snapN, greaterThanOrEqualTo(1),
        reason: 'zoom 应该走 SDK 的 SnapshotWidget 快照路径');
    for (final PageTransitionStyle s in PageTransitionStyle.values) {
      if (s == PageTransitionStyle.zoom) continue;
      expect(rs[s]!.snapN, 0, reason: '风格 ${s.name} 不该出现 SnapshotWidget');
    }
    for (final PageTransitionStyle s in <PageTransitionStyle>[
      PageTransitionStyle.slideRight,
      PageTransitionStyle.slideUp,
      PageTransitionStyle.fadeUp,
    ]) {
      expect(rs[s]!.slideN, greaterThanOrEqualTo(1),
          reason: '风格 ${s.name} 应通过 SlideTransition 落地');
    }
    expect(rs[PageTransitionStyle.fade]!.slideN, 0);
    expect(rs[PageTransitionStyle.none]!.slideN, 0);

    // ④ ★ Lead 的判据：同一页上，两个风格的入场读数必须不同
    final _Reading a = rs[PageTransitionStyle.slideRight]!;
    final _Reading b = rs[PageTransitionStyle.none]!;
    expect(a.routeMs, isNot(b.routeMs));
    expect(a.delta.dx - b.delta.dx, greaterThan(20.0),
        reason: 'slideRight 与 none 在同一页上的入场位移必须拉开');

    // 位移读数两两不同（除 fade/none 这一对：它们本来就都只动透明度）
    final Set<String> shapes = <String>{
      for (final _Reading r in rs.values)
        '${r.delta.dx.toStringAsFixed(2)},${r.delta.dy.toStringAsFixed(2)}',
    };
    expect(shapes.length, greaterThanOrEqualTo(4),
        reason: '六个风格应给出至少 4 种不同的入场位移读数，实际 $shapes');
  });

  testWidgets('disableAnimations=true：所有风格的入场读数都塌成 none 的读数', (
    WidgetTester t,
  ) async {
    _mount(t);

    final _Reading noneOn =
        await _measure(t, style: PageTransitionStyle.none, reduceMotion: false);
    final _Reading noneOff =
        await _measure(t, style: PageTransitionStyle.none, reduceMotion: true);
    _rec(noneOn.line);
    _rec(noneOff.line);

    // none 本身不受 Reduce Motion 影响
    expect(noneOff.delta, noneOn.delta);
    expect(noneOn.delta, Offset.zero);

    for (final PageTransitionStyle s in <PageTransitionStyle>[
      PageTransitionStyle.slideRight,
      PageTransitionStyle.slideUp,
      PageTransitionStyle.fadeUp,
      PageTransitionStyle.fade,
      PageTransitionStyle.zoom,
    ]) {
      final _Reading r = await _measure(t, style: s, reduceMotion: true);
      _rec(r.line);

      // ★ 几何 / 结构与 none **逐位相同** ⇒ 开动画时的那点区分度没了
      expect(r.delta, noneOn.delta,
          reason: '${s.name} 在 Reduce Motion 下还有位移：${r.delta}');
      expect(r.delta, Offset.zero, reason: '${s.name} 在 Reduce Motion 下必须原地出现');
      expect(r.slideN, noneOn.slideN);
      expect(r.scaleN, noneOn.scaleN);
      expect(r.snapN, noneOn.snapN);
      expect(r.snapN, 0, reason: '${s.name} 在 Reduce Motion 下不该再有快照层');

      // ★ 已知取舍：`transitionDuration` 拿不到 context ⇒ 这里 routeMs 仍是
      //   Motion.base（画面已瞬间切换）。如实记录，不做"必须为 0"的断言。
      _rec('T50C|reduce-tradeoff|style=${s.name}|routeMs=${r.routeMs}'
          '|ctrlMs=${r.controllerMs}|doneMs=${r.completedMs}');
    }
  });
}
