// ══════════════════════════════════════════════════════════════════════
//  t447 —— 「黑色竖线」真的没了吗？（**像素级**，不是源码文本断言）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么必须量像素
//
// 前一轮的守卫（`t66` 的旧 A 组）是**源码文本断言**
// （`expect(tlSrc.contains('_drawPlayhead'), isFalse)`）——
// 它能证明"那段代码没了"，但**证明不了"屏幕上那根线没了"**。
// 两者之间隔着：`paint` 有没有别的路径画它 / 有没有别的地方叠加。
//
// ★ 而 Owner 的判据**只能是像素**：「一个黑色的竖着的线」。
//   ⇒ 本文件把判据放到**同一层**：真渲染 → 读像素 → 数暗色竖条。
//
// # 怎么读像素
//
// `tester.runAsync` + `RepaintBoundary.toImage()` 拿到真实光栅化结果
// （与 `.probe\t429_arm64_probe.dart` 的进程内仪器同一手法）。
//
// # 判据
// ```text
// ① 轨道那一带**不得**出现"宽 ≤ 3px 且高 ≥ 轨道高"的暗色竖条
// ② 阳性对照：四个箭头必须**仍然**画出来（否则"全删了"也会绿）
// ```
// ★ ② 是必须的：没有它，"把时间轴整个删掉"能让 ① 通过 ——
//   而 Owner 要的是"只保留四个箭头"。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_timeline.dart';
// `SkipEdge` 定义在弹窗文件里（`skip_timeline.dart` 只 `show SkipEdge` 转发）
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart' show SkipEdge;

/// 与生产一致的包装（照抄 `test/t66_skip_preview_test.dart` 的做法）
Widget _host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Center(child: child)),
  );
}

/// 把某个 key 的子树光栅化，返回 `(宽, 高, 像素)`（像素为 0xAARRGGBB）
Future<(int, int, Uint32List)> _raster(WidgetTester tester, Key key) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  late Uint32List px;
  late int w, h;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    w = img.width;
    h = img.height;
    final bytes = bd!.buffer.asUint8List();
    px = Uint32List(w * h);
    for (var i = 0; i < w * h; i++) {
      final r = bytes[i * 4], g = bytes[i * 4 + 1], b = bytes[i * 4 + 2];
      final a = bytes[i * 4 + 3];
      px[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }
    img.dispose();
  });
  return (w, h, px);
}

/// 亮度 —— ★ **必须先把透明像素合成到白底上**再算
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 我第一版在这里错了，记下来（2026-10-01）
/// ══════════════════════════════════════════════════════════════════════
/// `RepaintBoundary.toImage()` 出来的是**透明背景**（alpha = 0）——
/// 那棵子树自己没画底，`Scaffold` 的白底**不在**这个 boundary 里。
///
/// 我第一版直接按 RGB 算亮度：
/// ```text
/// 透明像素 = (0,0,0,0) ⇒ 亮度 0 ⇒ 判成"黑"
/// ⇒ 760 列**全部**被判成"暗色竖条"
/// ```
/// ★ 那是**尺子错了**，不是被测物错了 —— 与项目里
///   「错的是尺子，不是被测物」（`.probe\VERIFY-LESSONS.md` #432）
///   是同一类：**判据必须先处理"这个像素是不是有效观测"**。
///
/// ⇒ 正确做法：按 alpha 合成到**白底**（与弹窗实际底色一致）——
///   这既让"透明"不再冒充黑色，也**模拟了用户真正看到的画面**。
double _lum(int argb) {
  final a = ((argb >> 24) & 0xFF) / 255.0;
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  // 合成到白底：out = src*a + 255*(1-a)
  final rr = r * a + 255 * (1 - a);
  final gg = g * a + 255 * (1 - a);
  final bb = b * a + 255 * (1 - a);
  return 0.299 * rr + 0.587 * gg + 0.114 * bb;
}

/// 找"暗色竖条"的列号
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 判据改过**两次**，都记清楚为什么
/// ══════════════════════════════════════════════════════════════════════
///
/// # 第一版（错的）：`暗像素数 >= 图高 × 0.6`
/// 阳性对照立刻红：我**故意画**的 14px 黑竖线在 120px 高的图里
/// 只占 11.7% ⇒ 够不到 60% ⇒ **仪器看不见它**。
/// ★ 而它"看不见"的方式是**返回空列表** —— 与"真的没有竖条"
///   **读数完全一样**。这正是「0 分不出『没有』与『没测到』」那条
///   （`.probe\VERIFY-LESSONS.md` #516）。
///
/// # 第二版：**按"连续暗像素的竖直跨度"判，不按整图比例**
/// ```text
/// 对每一列：找出它**最长的一段连续暗像素**（run length）
/// 判据：run >= minRun  ⇒  这一列有一根"竖条"
/// ```
/// ⇒ `minRun` 由调用方按**被测元素的真实高度**给（轨道 8px ⇒ 给 10），
///   与图有多高**无关**。
/// ★ 这样 14px 的黑线在 120px 的图里照样被抓到。
///
/// ⚠️ 用"连续段"而不是"暗像素总数"：文字/图标会在同一列散落几个暗像素，
///    但**不会连续**；竖条的特征恰恰是**连续**。
///
/// # 第三版（2026-10-02）：**必须排除刻度文字所在的 y 带**
/// 我给时间轴加了**时间刻度**（`0:00` 左、`47:06` 右、`▶ 05:00` 跟随），
/// 画在画布底部（y = canvasH-6 往上）。
/// ★ 中文/数字笔画**天然是"连续暗像素"** —— 一个「0」的竖笔就是 8-10px
///   连续暗，**正好够到 `minRun`** ⇒ 被误判成"竖条" ⇒ **假红**。
/// 实测：报出 `[21..30]`（`0:00`）与 `[718..738]`（`47:06`）。
/// ⇒ 新增 `yTop`/`yBottom` 参数，把**刻度文字那一条**排除在外。
///
/// ⚠️ 排除带**不能**盖住轨道与箭头：
/// ```text
/// 轨道 y = 28..36（`trackTop = (64-8)/2`）
/// 箭头 y ≈ 13..43（以轨道中心为中心，高 30）
/// 刻度 y ≈ 48..58（贴着底边）
/// ⇒ 只排除 y >= 46 就够，不会碰到箭头/轨道
/// ```
List<int> _findDarkBars(
  Uint32List px,
  int w,
  int h, {
  int minRun = 10,
  int yTop = 0,
  int? yBottom,
}) {
  final yb = yBottom ?? h;
  final bars = <int>[];
  for (var x = 0; x < w; x++) {
    var best = 0, cur = 0;
    for (var y = yTop; y < yb && y < h; y++) {
      if (_lum(px[y * w + x]) < 128) {
        cur++;
        if (cur > best) best = cur;
      } else {
        cur = 0;
      }
    }
    if (best >= minRun) bars.add(x);
  }
  return bars;
}

void main() {
  group('t447 「黑色竖线」像素级验证', () {
    testWidgets('★★★ 仪器阳性对照：它**能**看见一根黑色竖线', (WidgetTester tester) async {
      /*
       * ★★★ 这条是**仪器灵敏度证明**，必须先过 —— 否则下面
       *    "没找到竖条"可能只是"尺子看不见竖条"。
       *
       * 手法：故意画一根和原来播放头**一模一样**的黑竖线
       *（2px 宽、上下各伸 3px、近黑色），断言仪器抓得到它。
       * ⇒ 这样"轨道那一带没竖条"才是**有信息量**的阴性结论。
       */
      const key = ValueKey('t447-control');
      tester.view.physicalSize = const Size(800, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(
        RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 760,
            height: 120,
            child: Stack(
              children: [
                // 浅色轨道（与真实时间轴的轨道同色系）
                Positioned(
                  left: 10,
                  right: 10,
                  top: 58,
                  height: 8,
                  child: ColoredBox(color: const Color(0xFFF5F5F5)),
                ),
                // ★ 故意画一根黑竖线（复刻已删掉的播放头）
                Positioned(
                  left: 60,
                  top: 55,
                  width: 2,
                  height: 14,
                  child: ColoredBox(color: const Color(0xFF171717)),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final (w, h, px) = await _raster(tester, key);
      final bars = _findDarkBars(px, w, h);
      // ignore: avoid_print
      print('T447-CONTROL|尺寸 ${w}x$h  抓到的暗竖条列 = $bars');
      expect(bars, isNotEmpty,
          reason: '★★★ 仪器失效：连一根**故意画的**黑竖线都看不见 ⇒ '
              '下面那条"没找到竖条"的阴性结论**没有信息量**');
    });

    testWidgets('★★★ 轨道那一带不得有暗色竖条（Owner 的判据）',
        (WidgetTester tester) async {
      const key = ValueKey('t447-timeline');
      tester.view.physicalSize = const Size(800, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(
        RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 760,
            height: 120,
            child: SkipTimeline(
              total: 600,
              // ★ position = 0 ⇒ 播放头（若还在）会落在**最左端** ——
              //   正是 Owner 截图里那根线的位置（实测 x=20/780）
              position: 0,
              introStart: 30,
              introEnd: 90,
              outroStart: 500,
              outroEnd: 560,
              onSeek: (_) {},
              onChanged: (_, __) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final (w, h, px) = await _raster(tester, key);
      expect(w, greaterThan(100));
      expect(h, greaterThan(10));

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 判据必须**排除四个箭头所在的位置**（第二版修正）
       * ══════════════════════════════════════════════════════════════
       *
       * 第一版直接"全图找暗竖条"，实测抓到：
       * ```text
       * [36..49] [135..148] [598..612] [697..711]   ← 四组，每组 ~14px 宽
       * ```
       * ★ 那**正是四个箭头**（琥珀 #A8720A 与蓝 #1F4FD8 的亮度都 < 128，
       *   所以被判成"暗"）—— 它们是**要保留**的东西。
       *
       * ⇒ 判据改成：**在箭头位置之外**找暗竖条。
       *
       * # 箭头位置怎么算（**与生产同一个公式**）
       * `tipX[edge]` 是箭头的语义 x；箭头本体以它为中心，
       * 宽 `kArrowW`（朝左时向 +x 展开，朝右时向 -x 展开）。
       * ⇒ 这里用 `computeSkipTips`（**公开的几何纯函数**，
       *   与画家共用同一个 `xOfTip`）算出四个 x，
       *   然后按 `kArrowW + 余量` 把那段**排除**。
       *
       * ⚠️ 用公开函数而不是"目测那几列" —— 目测出来的列号
       *    在窗口宽度变化时立刻失效（那是把"读数"当"常量"用）。
       */
      final tips = computeSkipTips(
        width: 760,
        total: 600,
        introStart: 30,
        introEnd: 90,
        outroStart: 500,
        outroEnd: 560,
      );
      final arrowXs = <double>[
        for (final e in SkipEdge.values)
          if (tips[e] != null) tips[e]!,
      ];
      // 箭头本体宽 kArrowW，朝左时向右展开 ⇒ 取 [x - w, x + w] 再放宽一点
      const margin = 4.0;
      final excluded = <int>{};
      for (final ax in arrowXs) {
        for (var x = (ax - kArrowW - margin).floor();
            x <= (ax + kArrowW + margin).ceil();
            x++) {
          if (x >= 0 && x < w) excluded.add(x);
        }
      }

      /*
       * ★★★ 2026-10-02：还要排除**刻度文字**所在的 y 带
       *
       * 时间轴画布高 64（`_canvasH`），布局：
       * ```text
       * y  0..13   空
       * y 13..43   四个箭头（以轨道中心为中心，高 30）
       * y 28..36   轨道（8px）
       * y 44..58   ★ 刻度文字（`0:00` / `▶ 05:00` / `47:06`）
       * ```
       * ★ 数字笔画**天然是连续暗像素**（一个「0」的竖笔 8-10px）
       *   ⇒ 会被 `_findDarkBars` 误判成"竖条" ⇒ **假红**。
       * ⇒ 只扫 y < 46（**不碰轨道与箭头**）。
       *
       * ⚠️ 判据仍然是"轨道那一带"—— 播放头原本就画在
       *    `trackTop-3 .. trackTop+trackH+3` = **25..39**，
       *    落在 y<46 里 ⇒ 真的回来了照样抓得到（**灵敏度不变**）。
       */
      const scanYBottom = 46;

      final allBars = _findDarkBars(
        px, w, h,
        minRun: 10,
        yBottom: scanYBottom,
      );
      final bars = allBars.where((x) => !excluded.contains(x)).toList();

      // ignore: avoid_print
      print('T447|尺寸 ${w}x$h  扫描 y 带 = 0..$scanYBottom'
          '（排除刻度文字）');
      // ignore: avoid_print
      print('T447|箭头 x = $arrowXs  排除列数 = ${excluded.length}');
      // ignore: avoid_print
      print('T447|全部暗竖条列 = $allBars');
      // ignore: avoid_print
      print('T447|★ 排除箭头后剩下的竖条列 = $bars');

      expect(
        bars, isEmpty,
        reason: '★★★ 四个箭头**之外**出现了"暗色竖条"（列 $bars）—— '
            'Owner 报的「黑色的竖着的线」又回来了。'
            '若 `_drawPlayhead` 已删，则说明**还有别的绘制路径**在画它。'
            '（全部暗竖条列 = $allBars，其中箭头占 ${allBars.length - bars.length} 列）',
      );
    });

    testWidgets('★★★ 阳性对照：四个箭头必须仍在（防"删过头"）',
        (WidgetTester tester) async {
      const key = ValueKey('t447-arrows');
      tester.view.physicalSize = const Size(800, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(
        RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 760,
            height: 120,
            child: SkipTimeline(
              total: 600,
              position: 300,
              introStart: 30,
              introEnd: 90,
              outroStart: 500,
              outroEnd: 560,
              onSeek: (_) {},
              onChanged: (_, __) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final (w, h, px) = await _raster(tester, key);

      /*
       * 箭头的判据：**琥珀色**（`skipIntroColor(light)` = #A8720A）
       * 与**蓝色**（`skipOutroColor(light)` = #1F4FD8）必须都出现。
       *
       * ⚠️ 用"色相接近"而不是"精确等于" —— 抗锯齿会混色。
       *   判据：r 明显大于 b（琥珀）/ b 明显大于 r（蓝）。
       */
      var amber = 0, blue = 0;
      for (var i = 0; i < w * h; i++) {
        final r = (px[i] >> 16) & 0xFF, g = (px[i] >> 8) & 0xFF, b = px[i] & 0xFF;
        if (r > 120 && r > b + 60 && g > b) amber++;
        if (b > 120 && b > r + 60) blue++;
      }

      // ignore: avoid_print
      print('T447|琥珀像素=$amber  蓝色像素=$blue');
      expect(amber, greaterThan(50),
          reason: '★★★ 片头（琥珀）箭头不见了 —— '
              'Owner 要的是"只保留四个箭头"，删播放头不能连带删掉箭头');
      expect(blue, greaterThan(50),
          reason: '★★★ 片尾（蓝）箭头不见了 —— 同上');
    });
  });
}
