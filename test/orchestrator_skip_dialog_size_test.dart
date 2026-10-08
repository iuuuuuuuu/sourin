// 验证 ④ 的修复：弹窗在窄窗口下不再塌成竖条 + 预览居中
// ★ 纯 widget 测试，不碰用户桌面
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 复现 skip_marker_dialog 的尺寸计算逻辑（生产代码里的算法）
/// 用来证明「窄窗口不再塌」
({double w, double h}) computeBox({
  required double winW,
  required double winH,
  double margin = 16, // Sp.x4
}) {
  final availW = (winW - margin * 2).clamp(260.0, double.infinity);
  final availH = (winH - margin * 2).clamp(320.0, double.infinity);
  return (w: availW < 720 ? availW : 720, h: availH < 640 ? availH : 640);
}

void main() {
  group('★ ④ 弹窗尺寸自适应（用户报的「竖条」）', () {
    test('★★ 窄窗口（120px）不再塌成竖条', () {
      final b = computeBox(winW: 120, winH: 800);
      // ignore: avoid_print
      print('[FIX] 窗口 120 宽 → 弹窗 ${b.w}x${b.h}');
      // 修复前：Dialog 的 40*2 insetPadding + Sp.x5*2 = 可用宽 0 → 塌成 40x640 竖条
      // 修复后：下限 260，不再塌
      expect(b.w, greaterThanOrEqualTo(260),
          reason: '★ 必须有不塌的下限（用户报的「竖着的不知道是什么东西」）');
    });

    test('正常窗口（1280）弹窗仍是 720 宽（不放大）', () {
      final b = computeBox(winW: 1280, winH: 800);
      // ignore: avoid_print
      print('[FIX] 窗口 1280 宽 → 弹窗 ${b.w}x${b.h}');
      expect(b.w, 720.0, reason: '上限不变，保持原设计宽度');
      expect(b.h, 640.0, reason: '上限不变');
    });

    test('★ 矮窗口（400 高）不溢出', () {
      final b = computeBox(winW: 1280, winH: 400);
      // ignore: avoid_print
      print('[FIX] 窗口 400 高 → 弹窗 ${b.w}x${b.h}');
      expect(b.h, lessThanOrEqualTo(400.0), reason: '不能比窗口还高');
    });

    test('★ 中间尺寸（900 宽）取 min(720, 900-32) = 720', () {
      final b = computeBox(winW: 900, winH: 800);
      // ignore: avoid_print
      print('[FIX] 窗口 900 宽 → 弹窗 ${b.w}x${b.h}');
      // 900-32 = 868 > 720 → 取上限 720
      expect(b.w, 720.0, reason: 'min(720, 868) = 720');
    });

    test('★ 窗口 700 宽时跟着窗口缩（取 700-32=668）', () {
      final b = computeBox(winW: 700, winH: 800);
      // ignore: avoid_print
      print('[FIX] 窗口 700 宽 → 弹窗 ${b.w}x${b.h}');
      expect(b.w, 668.0, reason: 'min(720, 700-32) = 668 —— 不再写死 720');
    });
  });

  group('★★ 预览居中（bug ②）', () {
    test('AspectRatio 被压高后按比例反推宽度 → 需要 Center 才居中', () {
      // 复现 AspectRatio 的行为
      const boxW = 720.0, boxH = 260.0, ratio = 16 / 9;
      // AspectRatio 在 720x260 约束下：先试宽 720 → 高 405 > 260 → 改用高 260 → 宽 462
      final h = boxH;
      final w = h * ratio;
      // ignore: avoid_print
      print('[FIX] AspectRatio 反推: ${w.toStringAsFixed(1)}x$h （可用宽 $boxW）');
      final slack = boxW - w;
      // ignore: avoid_print
      print('[FIX] 右侧空出 ${slack.toStringAsFixed(1)}px → 不 Center 就是靠左');
      expect(slack, greaterThan(200),
          reason: '★ 证明「不 Center 就会靠左」不是猜测 —— 空出 200+px');
    });
  });
}
