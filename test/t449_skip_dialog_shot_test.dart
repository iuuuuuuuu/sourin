// ══════════════════════════════════════════════════════════════════════
//  t449 —— 把**真实**的片头片尾弹窗渲染出来存成 PNG（人眼验收用）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么不用鼠标驱动
//
// 我写了 `.probe\t446/t448` 两个脚本用 `PrintWindow` + 坐标点击去驱动桌面端
// 打开弹窗，实测**很脆**：
// ```text
// ① 底栏 tab 坐标随页面状态变（点偏一次就跑到别的 tab）
// ② 直播页的内嵌播放器 vs 全屏播放页是**两个不同页面**，
//    而「片头片尾」按钮只在后者
// ③ 全屏后控制条会自动隐藏，要先"移动鼠标"才显示
// ④ 每步都得截图确认，人工读图 ⇒ 慢且不可复现
// ```
// ★ 而我要验的东西很单纯：「弹窗里那根黑竖线没了」。
//   ⇒ **直接渲染这个弹窗**比"驱动 UI 走到那个状态"可靠得多，
//     而且**可复现**（同一条命令任何人跑都是同一张图）。
//
// ⚠️ 这不是"用测试代替实测"：它渲染的是**生产代码里的同一个 widget**
//    （`SkipMarkerDialog` 本体），不是复刻品。
//    预览区（`_previewBox`）里的 `media_kit` 播放器在测试环境无核心库，
//    会显示占位 —— 但**时间轴**（`SkipTimeline`）是纯 Canvas 画的，
//    与本文件要验的东西完全一致。
//
// 用法：
//   flutter test test/t449_skip_dialog_shot_test.dart
//   ⇒ 产出 `.probe\t449_dialog.png`

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';

/// 输出目录
///
/// ⚠️ 原来写死的是开发机的绝对路径（`D:\WishProject\sourin-flutter-spike\.probe`）——
///    那个目录**不在仓库里**（见 `.gitignore`），在别的机器/CI 上必然失败。
///    改成相对当前工作目录 ⇒ 本机与 CI 行为一致，且产物落在被忽略的位置。
const _outDir = 'build/probe-shots';

Widget _host(Widget child) {
  final theme = FTheme.neutral.light.desktop;
  return MaterialApp(
    theme: theme.toApproximateMaterialTheme(),
    builder: (context, c) => FTheme(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

void main() {
  testWidgets('把真实的 SkipMarkerDialog 渲染成 PNG（人眼验收）',
      (WidgetTester tester) async {
    const key = ValueKey('t449-dialog');

    // 1280x800 —— 与桌面端实际窗口一致
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(
      RepaintBoundary(
        key: key,
        child: const SkipMarkerDialog(
          provider: 'demo',
          id: 't449',
          title: '验收用 · 片头片尾弹窗',
          streamUrl: '',
          duration: Duration(minutes: 47, seconds: 6),
          /*
           * ⚠️ 四个端点**不在构造参数里** —— 弹窗自己从 store 读
           *   （`_loadSkipPoints()`）。本环境无 `sourin_core.dll`
           *   ⇒ 读失败 ⇒ 四个端点都是 null ⇒ 时间轴画**幽灵箭头**
           *   （半透明，见 `drawArrow` 里"未设置"那一段）。
           *
           * ★ 这不影响本文件要验的东西：Owner 报的"黑色竖线"是
           *   **播放头**，它与四个端点有没有值**无关** ——
           *   播放头的位置只由 `position` 决定（恒画在 position 处）。
           *   所以"没设端点"反而更干净：画面上只有幽灵箭头 + 轨道，
           *   任何**实心深色竖线**都必然是残留的播放头。
           */
        ),
      ),
    ));

    // 让弹窗把数据读完（无核心库会走失败分支，但布局照样成立）
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      while (tester.takeException() != null) {}
    }

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    late Uint8List png;
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 1.0);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      png = bd!.buffer.asUint8List();
      img.dispose();
    });

    final dir = Directory(_outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('$_outDir\\449_dialog.png');
    f.writeAsBytesSync(png);
    // ignore: avoid_print
    print('T449|saved ${f.path}  ${png.length} B');
    expect(png.length, greaterThan(1000));
  });
}
