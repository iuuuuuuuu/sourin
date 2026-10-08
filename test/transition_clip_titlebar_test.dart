// ═══════════════════════════════════════════════════════════════════════
//  转场期间，离场页放大溢出的内容**不得**画到标题栏区域（任务㉗④）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（2026-09-25）
//
// > 打开播放详情页的时候还是有白色的条会覆盖操作条,这个不能优化掉吗?
// > 太影响观感了
//
// # 根因（逐帧实测 + 算术双重确认）
//
// 白条**不是**标题栏收起（详情页根本不碰 `titleBarVisible`），
// 而是**离场页被放大后画到了标题栏上面**：
// ```text
// 正常     标题栏 y=0..39（40px，= preferredSize），内容从 y=40 开始
// 转场中   标题栏仍从 y=0 开始，但**被压到 y=0..22**
//          纯白 #ffffff 填满 y=23..39（正是被压掉的那 17px）
// ```
// 白条**上边缘在动**（t=213ms → y=23，t=375ms → y=21）⇒ 它在**变大**，
// 是缩放动画的特征。算术对得上 `_ZoomExitTransition._scaleUpTransition`：
// ```text
// Navigator 高 = 800 − 40 = 760
// scale 1.04 → 上溢 (760×0.04)/2 = 15.2px → y≈24.8
// scale 1.05 → 上溢 19.0px               → y≈21.0
// ★ 实测 y=23..21 正好落在这两个值之间
// ```
// 而 Flutter 源码里 `_ZoomExitTransitionState.build()` 返回
// `SnapshotWidget(painter: _ZoomExitTransitionPainter(...))` ——
// **painter 直接画**，这正是它能画到自己矩形之外的原因。
//
// # ★★★ 这个测试最大的坑：**必须把平台设成 windows**
//
// 我第一版**没有**指定平台，红度证明失败（去掉 ClipRect 也测不到溢出），
// 于是我一度**推翻了自己的根因**。实测（`.probe/probe_tests/t27_platform_probe_test.dart`）：
// ```text
// [PROBE] defaultTargetPlatform = TargetPlatform.android        ← ★ 不是 windows！
// [PROBE] ★ 当前平台实际用到的 builder = PredictiveBackPageTransitionsBuilder
// ```
// `flutter_tester` 默认跑 **android**，而 `PageTransitionsTheme._defaultBuilders`
// 是**按平台**选的：
// ```text
// android  → PredictiveBackPageTransitionsBuilder()   ← 不缩放
// windows  → ZoomPageTransitionsBuilder()             ← 真机走这条（会放大到 1.05）
// ```
// ⇒ 我的测试用的是**一个不缩放的转场**，自然测不到溢出。
// **"红度证明失败"是我的测试环境错，不是根因错。**
//
// ⇒ 修法：显式把平台设成 windows。★ 用 `ThemeData.platform`（而不是
//   `debugDefaultTargetPlatformOverride` —— 后者会被 flutter_test 的
//   "foundation debug 变量必须还原"校验拦下，因为 `addTearDown` 跑在校验之后）。
//
// # 另外两个真实踩过的坑
//
// ```text
// ① `toImage()` 必须包在 `tester.runAsync()` 里
//    flutter_test 默认在 fake-async zone 跑，而 toImage() 的 Future 由
//    **引擎光栅线程**完成 ⇒ 直接 await 会**永久挂起**
//    （我第一版挂了 600 秒被杀掉）。runAsync 里**不能** pump。
// ② ★ 不能用 `find.byType(RepaintBoundary).first` 取图
//    Flutter 自己在多处插了 RepaintBoundary（Navigator 的 _ModalScope 等），
//    `.first` 拿到的是别人的 —— 我第一版期望"标题栏 0 白"，实际 51200
//    （= 1280×40，正好是**标题栏自己**的尺寸 ⇒ 截到的是一张 40px 高的图）。
//    ⇒ 必须用**自己的、带 Key 的** boundary，并断言图尺寸。
// ```
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/theme_bridge.dart';

/// 抓图用的 RepaintBoundary Key —— 必须是**我们自己的**，不能靠 `.first`
const _captureKey = ValueKey<String>('t27-capture');

/// 标题栏的颜色（可辨识的深色；用纯白页去撞它最容易看出溢出）
const _titleBarColor = Color(0xFF101820);

/// 复刻 `shell.dart` 的 `_TitleBarHost` 结构：
/// 标题栏（40px）在 Navigator **之外**，内容可选地用 `ClipRect` 包住。
///
/// `clip` = true 是修复后的形态；false 是修复前（用来做红度证明）。
Widget _appWithHost({required Widget home, required bool clip}) {
  return MaterialApp(
    theme: ThemeData(
      // ★★★ 必须显式指定 platform = windows
      //
      // 我第一版没指定，红度证明假失败，害我一度**推翻自己的根因**。
      // 实测（`.probe/probe_tests/t27_platform_probe_test.dart`）：
      // ```text
      // [PROBE] defaultTargetPlatform = TargetPlatform.android   ← ★ 不是 windows
      // [PROBE] ★ 实际用到的 builder = PredictiveBackPageTransitionsBuilder
      // ```
      // `flutter_tester` 默认跑 android，而 `PageTransitionsTheme` 是**按平台**
      // 选的：android 用 `PredictiveBackPageTransitionsBuilder`（**不缩放**），
      // windows 才用 `ZoomPageTransitionsBuilder`（离场放大到 1.05）。
      // ⇒ 不指定平台 = 测了一个**不缩放**的转场 = 永远测不到溢出。
      //
      // ⚠️ 不能用 `debugDefaultTargetPlatformOverride`：flutter_test 会在每个
      //    测试结束时校验"foundation debug 变量已还原"，而 `addTearDown`
      //    跑在**校验之后** ⇒ 必然报
      //    "The value of a foundation debug variable was changed by the test."
      // ★ 正解：`PageTransitionsTheme.buildTransitions` 读的是
      //    `Theme.of(context).platform`（源码 L870）⇒ 直接设 `ThemeData.platform`
      //    既准确又无副作用。
      platform: TargetPlatform.windows,
      pageTransitionsTheme: buildPageTransitionsTheme(),
    ),
    builder: (context, child) {
      final content = child ?? const SizedBox();
      return RepaintBoundary(
        key: _captureKey,
        child: Column(
          children: [
            const SizedBox(
              height: 40,
              width: double.infinity,
              child: ColoredBox(color: _titleBarColor),
            ),
            Expanded(child: clip ? ClipRect(child: content) : content),
          ],
        ),
      );
    },
    home: home,
  );
}

/// 一页**纯白**内容 —— 正是用户看到的"白条"的来源
class _WhitePage extends StatelessWidget {
  const _WhitePage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Center(child: Text(label)),
      );
}

void main() {
  /// 设置视口尺寸。
  ///
  /// ★ 平台**不在这里**设 —— 由 `ThemeData.platform` 指定（见 `_appWithHost`）。
  ///   我第一版用 `debugDefaultTargetPlatformOverride`，框架直接报：
  ///   ```text
  ///   The value of a foundation debug variable was changed by the test.
  ///     debugAssertAllFoundationVarsUnset ...
  ///   ```
  ///   因为 flutter_test 在每个测试结束时校验"foundation debug 变量已还原"，
  ///   而 `addTearDown` 跑在**校验之后** ⇒ 必然报错（放进 `setUp`/`tearDown`
  ///   也一样）。⇒ 改用 `ThemeData.platform`，它正是
  ///   `PageTransitionsTheme.buildTransitions` 真正读取的来源（源码 L870）。
  void setUpViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 统计标题栏区域里**偏离标题栏颜色**的像素数。
  ///
  /// 判据是**不变量**：标题栏在 Navigator 之外，**不参与**路由转场
  /// ⇒ 它的像素必须逐字节恒等于自己的颜色，任何偏差 = 有东西画到了它上面。
  /// （不需要猜"纯白"阈值 —— 转场中页面在淡入淡出，半透明白会被压暗。）
  Future<(int deviated, int w, int h)> titleBarDeviation(
    WidgetTester tester,
  ) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final data = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bd = await image.toByteData();
      final w = image.width, h = image.height;
      image.dispose();
      return (bd!.buffer.asUint8List(), w, h);
    });
    final (bytes, w, h) = data!;
    final dpr = tester.view.devicePixelRatio;
    final limit = (40 * dpr).round().clamp(0, h);
    var bad = 0;
    for (var y = 0; y < limit; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        if (bytes[i] != (_titleBarColor.r * 255).round() ||
            bytes[i + 1] != (_titleBarColor.g * 255).round() ||
            bytes[i + 2] != (_titleBarColor.b * 255).round()) {
          bad++;
        }
      }
    }
    return (bad, w, h);
  }

  /// 转场期间逐时刻取标题栏的最大偏差。
  ///
  /// ★ 多时刻采样：离场缩放是**渐进**的，只测一个时刻可能正好错过峰值。
  Future<(int worst, int w, int h)> worstDeviationDuringTransition(
    WidgetTester tester,
  ) async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(builder: (_) => const _WhitePage(label: '详情')),
    );
    await tester.pump(); // 启动路由

    var worst = 0;
    var w = 0, h = 0;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      final (bad, iw, ih) = await titleBarDeviation(tester);
      if (bad > worst) worst = bad;
      w = iw;
      h = ih;
    }
    return (worst, w, h);
  }

  group('任务㉗④ 转场放大溢出不得画到标题栏上', () {
    testWidgets('修复后：转场全程标题栏像素不被覆盖', (tester) async {
      setUpViewport(tester);

      await tester.pumpWidget(
        _appWithHost(clip: true, home: const _WhitePage(label: '首页')),
      );
      await tester.pumpAndSettle();

      final (atRest, bw, bh) = await titleBarDeviation(tester);
      expect(bw, 1280, reason: '抓到的图宽度必须是整个窗口 1280');
      expect(bh, 800, reason: '抓到的图高度必须是整个窗口 800');
      expect(atRest, 0, reason: '静止时标题栏必须完全是自己的颜色');

      final (worst, w, h) = await worstDeviationDuringTransition(tester);
      expect(
        worst,
        0,
        reason: '转场期间标题栏出现了 $worst 个被覆盖的像素'
            '（图 ${w}x$h）—— 这就是用户报的"白色的条会覆盖操作条"。'
            '离场页被放大到 1.05 后溢出到 Navigator 之外，'
            '`ClipRect` 应当把它裁掉',
      );

      await tester.pumpAndSettle();
    });

    testWidgets('红度证明：去掉 ClipRect 后标题栏会被溢出内容覆盖', (tester) async {
      setUpViewport(tester);

      await tester.pumpWidget(
        _appWithHost(clip: false, home: const _WhitePage(label: '首页')),
      );
      await tester.pumpAndSettle();

      final (worst, w, h) = await worstDeviationDuringTransition(tester);

      // ★ 红度证明：没有 ClipRect 时**必须**看得到溢出。
      //   若这里也是 0，说明本测试**测不出**这个 bug ⇒
      //   第一条测试的 "0" 就不能作为证据（铁律②：判据测不出反面 ⇒ 结论作废）。
      expect(
        worst,
        greaterThan(0),
        reason: '没有 ClipRect 时，转场放大的离场页应当溢出并覆盖标题栏 —— '
            '如果这里也是 0（图 ${w}x$h），说明本测试测不出这个 bug，'
            '那么"有 ClipRect 时是 0"就不能证明修复有效。'
            '⚠️ 先确认平台是 windows（android 的 PredictiveBack 不缩放）',
      );

      await tester.pumpAndSettle();
    });
  });
}
