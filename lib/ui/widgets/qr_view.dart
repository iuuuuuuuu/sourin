// ═══════════════════════════════════════════════════════════════════════
//  Dart 侧解析 Rust 生成的二维码 SVG（2026-09-23）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不引入 flutter_svg
//
// 硬性指标③要求 Windows 安装包 <50MB。`flutter_svg` 是一个纯 Dart 包
// （体积不大），但它要拉 `vector_graphics` + `vector_graphics_codec`
// + `vector_graphics_compiler` 一串依赖。
//
// 而我们的需求**极其窄**：只渲染 `qrcode` crate 生成的那一种 SVG，
// 结构完全固定（实测确认）：
// ```xml
// <svg width="231" height="231" viewBox="0 0 231 231">
//   <rect x="0" y="0" width="231" height="231" fill="#ffffff"/>
//   <path fill="#0b0d12" d="M28 28h7v7H28V28M35 28h7v7H35V28..."/>
// </svg>
// ```
// 全部深色模块都在**一个 path** 里，每个模块是
// `M{x} {y}h{w}v{h}H{x}V{y}` —— 一个 w×h 的方块。
//
// 所以自己解析只要 30 行，比拉三个包划算得多。
//
// # ⚠️ 解析失败必须能降级
//
// 调用方（设置页）在解析失败时要**只显示 URL 文本** ——
// 二维码是便利功能，不是必需品，不该因为它挂了就整页报错。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 一个二维码模块（方块）
class QrModule {
  const QrModule(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;
}

/// 解析结果
class QrSvgData {
  const QrSvgData({
    required this.size,
    required this.modules,
    required this.dark,
    required this.light,
  });

  /// 画布尺寸（正方形，来自 `viewBox`）
  final double size;

  final List<QrModule> modules;
  final Color dark;
  final Color light;

  bool get isValid => size > 0 && modules.isNotEmpty;
}

/// 从 Rust 生成的 SVG 里解析出二维码
///
/// 返回 null 表示"结构不认识" —— 调用方应降级成只显示 URL。
QrSvgData? parseQrSvg(String svg) {
  if (svg.isEmpty) return null;

  // ── viewBox：拿画布尺寸 ──
  final vb = RegExp(r'viewBox="([\d.\s-]+)"').firstMatch(svg);
  double size;
  if (vb != null) {
    final parts = vb.group(1)!.trim().split(RegExp(r'\s+'));
    if (parts.length >= 4) {
      final w = double.tryParse(parts[2]);
      final h = double.tryParse(parts[3]);
      if (w == null || h == null || w <= 0) return null;
      // 二维码必然是正方形；不是就说明结构变了
      if ((w - h).abs() > 0.5) return null;
      size = w;
    } else {
      return null;
    }
  } else {
    // 没有 viewBox 就退回 width/height
    final wm = RegExp(r'width="([\d.]+)"').firstMatch(svg);
    final w = wm == null ? null : double.tryParse(wm.group(1)!);
    if (w == null || w <= 0) return null;
    size = w;
  }

  // ── 颜色 ──
  final rect = RegExp(r'<rect[^>]*fill="(#[0-9a-fA-F]{3,8})"').firstMatch(svg);
  final light = _parseHex(rect?.group(1)) ?? const Color(0xFFFFFFFF);

  final pathTag = RegExp(r'<path[^>]*fill="(#[0-9a-fA-F]{3,8})"').firstMatch(svg);
  final dark = _parseHex(pathTag?.group(1)) ?? const Color(0xFF000000);

  // ── 模块：解析 path 的 d 属性 ──
  final dm = RegExp(r'<path[^>]*\sd="([^"]+)"').firstMatch(svg);
  if (dm == null) return null;

  final modules = <QrModule>[];
  /*
   * 每条子路径形如 `M28 28h7v7H28V28`
   *
   * ```text
   * M{x} {y}    移动到左上角
   * h{w}        向右 w
   * v{h}        向下 h
   * H{x}        回到左边界
   * V{y}        回到上边界（闭合）
   * ```
   * 用正则逐条抓 —— 顺序固定，不需要写完整 SVG 路径解析器。
   */
  final re = RegExp(r'M([\d.]+) ([\d.]+)h([\d.]+)v([\d.]+)H([\d.]+)V([\d.]+)');
  for (final m in re.allMatches(dm.group(1)!)) {
    final x = double.tryParse(m.group(1)!);
    final y = double.tryParse(m.group(2)!);
    final w = double.tryParse(m.group(3)!);
    final h = double.tryParse(m.group(4)!);
    if (x == null || y == null || w == null || h == null) continue;
    modules.add(QrModule(x, y, w, h));
  }

  if (modules.isEmpty) return null;

  return QrSvgData(
    size: size,
    modules: modules,
    dark: dark,
    light: light,
  );
}

Color? _parseHex(String? hex) {
  if (hex == null) return null;
  var s = hex.replaceFirst('#', '');
  if (s.length == 3) {
    // #abc → #aabbcc
    s = s.split('').map((c) => '$c$c').join();
  }
  if (s.length == 6) s = 'ff$s'; // 补 alpha
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}

/// 二维码渲染组件
///
/// 用 `CustomPainter` 直接画方块 —— 比把 SVG 转成 widget 树快得多
/// （一个 231×231 的码有 400~600 个模块，逐个画矩形很轻）。
class QrView extends StatelessWidget {
  const QrView({
    super.key,
    required this.svg,
    this.size = 160,
    this.fallback,
  });

  /// Rust 生成的 SVG 原文
  final String svg;

  final double size;

  /// 解析失败时显示的内容（通常是 URL 文本）
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final data = parseQrSvg(svg);
    if (data == null || !data.isValid) {
      return SizedBox(
        width: size,
        height: size,
        child: fallback ??
            Center(
              child: Text(
                '二维码不可用',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _QrPainter(data),
        // 二维码是**浅底深码**：白底在深色主题上有点跳，
        // 但这是扫码识别率的前提（反色二维码很多扫描器不认）
        isComplex: false,
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data);

  final QrSvgData data;

  @override
  void paint(Canvas canvas, Size size) {
    // 把 SVG 坐标缩放到实际尺寸
    final k = math.min(size.width, size.height) / data.size;

    // 背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = data.light,
    );

    // 模块
    final p = Paint()..color = data.dark;
    for (final m in data.modules) {
      canvas.drawRect(
        Rect.fromLTWH(m.x * k, m.y * k, m.w * k, m.h * k),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}

/// 把二维码渲染成 PNG 字节（用于「保存到相册」等场景）
///
/// ⚠️ 目前没用到，但留着 —— 原版有"复制地址"按钮，
///    将来若加"保存二维码图片"会需要它。
Future<ui.Image> renderQrToImage(QrSvgData data, int px) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final k = px / data.size;

  canvas.drawRect(
    Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()),
    Paint()..color = data.light,
  );
  final p = Paint()..color = data.dark;
  for (final m in data.modules) {
    canvas.drawRect(Rect.fromLTWH(m.x * k, m.y * k, m.w * k, m.h * k), p);
  }

  return recorder.endRecording().toImage(px, px);
}
