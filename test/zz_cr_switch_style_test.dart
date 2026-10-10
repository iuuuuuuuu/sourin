// ═══════════════════════════════════════════════════════════════════════
//  OPS-8 · 开关（Switch）样式 —— 把「难看」里**可量化**的那部分钉死
// ═══════════════════════════════════════════════════════════════════════
//
// 业主原话（第二次反馈）：「这个switch开关样式还是很难看啊,再接着优化优化」
//
// 「难不难看」本身写不成断言，但业主看到的东西可以拆成三条**可测**性质：
//
//  ① 关态必须**有槽**：轨道与页面底色的对比度不能低到看不见
//     （改前深色 1.33:1 —— 看上去就是"一个悬空的白点"，没有槽）。
//  ② 开态拇指必须**读得出**：拇指与轨道的亮度差 ≥ 0.25
//     （改前深色 0.178、浅色 0.164 —— 看上去是"一根亮条中间一道黑缝"）。
//  ③ 开态必须用**调色板的主色对**：轨道 `primary` + 拇指 `primaryForeground`
//     （改前拇指用 `foreground`：浅色下成了"蓝底黑痣"）。
//
// 本文件**只**依赖主题，不 import 任何产品页面（页面要 FFI 核心，跑不起来）。
// 改前实测：13 条红（每个明暗 6 条 + 主题包 6 条里的若干），见
// `.probe/ops/OPS-8-switch-style.md` 里的 RED 原文。
// ignore_for_file: avoid_print — 光栅那一条要把实测像素数打出来当证据
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

bool _noop(bool v) => true;

// ── WCAG 相对亮度 / 对比度 ────────────────────────────────────────────
// 用标准公式而不是"眼睛估"：对比度是业主「看不看得见」的代理指标，
// 有公开算法就别自己发明。

double _lin(int channel) {
  final v = channel / 255.0;
  return v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

double _lum(Color c) {
  final v = c.toARGB32();
  return 0.2126 * _lin((v >> 16) & 0xFF) +
      0.7152 * _lin((v >> 8) & 0xFF) +
      0.0722 * _lin(v & 0xFF);
}

double _contrast(Color a, Color b) {
  final la = _lum(a);
  final lb = _lum(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// 把（可能半透明的）前景色按 alphaBlend 压到背景上再测 —— Switch 自己
/// 画拇指时就是这么干的（`Color.alphaBlend(thumb, surface)`）。不这样做的话，
/// 一个 5% alpha 的"幽灵轨道"也能拿到 1.0 的对比度读数，门禁就成了摆设。
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

// ── 光栅：证明「主题里写的颜色」真的画到了屏幕上 ──────────────────────
// ⚠️ `toImage()` 必须包在 `tester.runAsync()` 里 —— flutter_test 默认在
//    fake-async zone 跑，直接 await 会永远不完成（实测挂死）。

Future<({Uint8List px, int w, int h})> _raster(WidgetTester tester, Key key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  late Uint8List px;
  late int w;
  late int h;
  await tester.runAsync(() async {
    final img = await boundary.toImage();
    w = img.width;
    h = img.height;
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = bd!.buffer.asUint8List();
    img.dispose();
  });
  return (px: px, w: w, h: h);
}

/// 数出「等于某个颜色」的像素：个数 + 重心 x（±tol，容忍抗锯齿边）
///
/// 重心 x 是「滑块到底在哪一边」的**像素级**证据 —— 业主的诉求①
/// 是"滑块在开态靠右、关态靠左"，那就不能只信布局算出来的坐标。
({int n, double cx}) _blob(
  ({Uint8List px, int w, int h}) r,
  Color target, {
  int tol = 4,
}) {
  final v = target.toARGB32();
  final tr = (v >> 16) & 0xFF;
  final tg = (v >> 8) & 0xFF;
  final tb = v & 0xFF;
  var n = 0;
  var sx = 0.0;
  for (var y = 0; y < r.h; y++) {
    for (var x = 0; x < r.w; x++) {
      final i = (y * r.w + x) * 4;
      if ((r.px[i] - tr).abs() <= tol &&
          (r.px[i + 1] - tg).abs() <= tol &&
          (r.px[i + 2] - tb).abs() <= tol) {
        n++;
        sx += x;
      }
    }
  }
  return (n: n, cx: n == 0 ? -1 : sx / n);
}

Widget _host(Brightness b, Key key, bool value) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeFor(b),
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: key,
        child: Switch(value: value, onChanged: _noop),
      ),
    ),
  ),
);

const Set<WidgetState> _off = <WidgetState>{};
const Set<WidgetState> _on = <WidgetState>{WidgetState.selected};
const Set<WidgetState> _offDis = <WidgetState>{WidgetState.disabled};
const Set<WidgetState> _onDis = <WidgetState>{
  WidgetState.disabled,
  WidgetState.selected,
};

void main() {
  for (final b in Brightness.values) {
    group('开关样式 · ${b.name}', () {
      final c = AppTheme.colorsFor(b);
      final theme = AppTheme.themeFor(b);
      final st = theme.switchTheme;

      Color? thumb(Set<WidgetState> s) => st.thumbColor!.resolve(s);
      Color? track(Set<WidgetState> s) => st.trackColor!.resolve(s);
      Color? edge(Set<WidgetState> s) => st.trackOutlineColor!.resolve(s);

      test('① 开态轨道 = 主题主色（用 tokens 主色，不另起色号）', () {
        expect(track(_on), theme.colorScheme.primary,
            reason: '开态必须落在调色板的 primary 上，外部主题包换主色时开关要跟着走');
      });

      test('② 开态拇指 = primaryForeground（与轨道成对，读得出）', () {
        expect(thumb(_on), c.primaryForeground,
            reason: '改前用 foreground：深色 #FAFAFA 压在 #E5E5E5 上、'
                '浅色 #1E2028 压在 #3B6FE0 上 —— 前者是业主说的「一道黑缝」，'
                '后者是「蓝底黑痣」');
      });

      test('③ 开态拇指与轨道的亮度差 ≥ 0.25', () {
        final gap = (_lum(thumb(_on)!) - _lum(track(_on)!)).abs();
        expect(gap, greaterThanOrEqualTo(0.25),
            reason: '实测 ${gap.toStringAsFixed(3)}（改前：深色 0.178 / 浅色 0.164）');
      });

      test('④ 关态轨道与页面底色的对比度 ≥ 1.5:1（槽看得见）', () {
        final painted = _over(track(_off)!, c.background);
        final r = _contrast(painted, c.background);
        expect(r, greaterThanOrEqualTo(1.5),
            reason: '${_hex(track(_off)!)} 压到底色 ${_hex(c.background)} 上 = '
                '${_hex(painted)}，对比度 ${r.toStringAsFixed(2)}:1'
                '（改前：深色 1.31、浅色 1.06）');
      });

      test('⑤ 关态描边必须与轨道不同色（否则画了等于没画）', () {
        final t = _over(track(_off)!, c.background);
        expect(_over(edge(_off)!, t), isNot(t),
            reason: '改前描边色恒等于轨道色：开态 = primary、关态 = secondary');
      });

      test('⑥ 关态描边与轨道的亮度差 ≥ 0.03（边要真的看得见）', () {
        final t = _over(track(_off)!, c.background);
        final e = _over(edge(_off)!, t);
        final gap = (_lum(e) - _lum(t)).abs();
        expect(gap, greaterThanOrEqualTo(0.03),
            reason: '轨道 ${_hex(t)} 上描边 ${_hex(e)} = 实测 ${gap.toStringAsFixed(3)}'
                '（改前：两条都是同一个色，0.000）');
      });

      test('⑦ 描边宽度 = 1.0（与 lib/ui 里 25 处 BorderSide 同一档）', () {
        expect(st.trackOutlineWidth!.resolve(_off), 1.0);
        expect(st.trackOutlineWidth!.resolve(_on), 1.0);
      });

      test('⑧ 禁用态半透明，与其它控件同一套语言', () {
        expect(thumb(_offDis)!.a, lessThan(0.9));
        expect(track(_offDis)!.a, lessThan(0.9));
        expect(edge(_offDis)!.a, lessThan(0.9));
        expect(thumb(_off)!.a, 1.0, reason: '非禁用态不许半透明');
        expect(track(_on)!.a, 1.0);
        expect(thumb(_onDis)!.a, thumb(_offDis)!.a);
      });

      testWidgets('⑨ 光栅：这套色真的画到了屏幕上（不是只在 ThemeData 里）',
          (tester) async {
        await tester.pumpWidget(_host(b, const ValueKey('off'), false));
        await tester.pumpAndSettle();
        final rOff = await _raster(tester, const ValueKey('off'));
        final offThumb = _blob(rOff, thumb(_off)!);
        final offTrack = _blob(rOff, track(_off)!);

        await tester.pumpWidget(_host(b, const ValueKey('on'), true));
        await tester.pumpAndSettle();
        final rOn = await _raster(tester, const ValueKey('on'));
        final onThumb = _blob(rOn, thumb(_on)!);
        final onTrack = _blob(rOn, track(_on)!);

        print('[raster] ${b.name} ${rOff.w}x${rOff.h} '
            '关: 拇指${_hex(thumb(_off)!)}×${offThumb.n} cx=${offThumb.cx.toStringAsFixed(1)} '
            '轨道${_hex(track(_off)!)}×${offTrack.n} | '
            '开: 拇指${_hex(thumb(_on)!)}×${onThumb.n} cx=${onThumb.cx.toStringAsFixed(1)} '
            '轨道${_hex(track(_on)!)}×${onTrack.n}');

        // 关态拇指是 16dp 的圆（≈200 像素），开态是 24dp（≈450 像素）
        expect(offThumb.n, greaterThanOrEqualTo(80), reason: '关态拇指没画出来');
        expect(offTrack.n, greaterThanOrEqualTo(200), reason: '关态轨道没画出来');
        expect(onThumb.n, greaterThanOrEqualTo(200), reason: '开态拇指没画出来');
        expect(onTrack.n, greaterThanOrEqualTo(200), reason: '开态轨道没画出来');

        // ★ 业主诉求①「滑块在开态靠右、关态靠左」—— 用像素重心量，
        //   不信布局算出来的坐标：60 逻辑像素宽的开关上要真的挪过去。
        expect(onThumb.cx - offThumb.cx, greaterThanOrEqualTo(10.0),
            reason: '关态重心 ${offThumb.cx.toStringAsFixed(1)} → '
                '开态重心 ${onThumb.cx.toStringAsFixed(1)}，滑块没挪到位');
      });

      testWidgets('⑩ 拨动是平滑位移（不是瞬间跳变）', (tester) async {
        var v = false;
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(b),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (ctx, setState) => Switch(
                  value: v,
                  onChanged: (x) => setState(() => v = x),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.byType(Switch));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.hasRunningAnimations, isTrue,
            reason: '拨到一半时应当还有过渡动画在跑（引擎默认 300ms）；'
                '若为 false 说明拇指是"瞬移"过去的');
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.hasRunningAnimations, isFalse,
            reason: '350ms 之后应当已经落位');
      });
    });
  }

  group('主题包：开关跟着包走（不许写死色号）', () {
    for (final pack in ThemePackStore.builtins) {
      test('${pack.id}：开态用包主色对，关态在包底色上仍看得见', () {
        final th = AppTheme.themeForPack(pack.brightness, pack);
        final p = pack.palette;
        final st = th.switchTheme;

        expect(st.trackColor!.resolve(_on), p.primary,
            reason: '开态轨道必须是这个包的主色');
        expect(st.thumbColor!.resolve(_on), p.primaryForeground,
            reason: '开态拇指必须是这个包的「主色之上」色');
        expect(st.trackOutlineWidth!.resolve(_off), 1.0);

        final painted = _over(st.trackColor!.resolve(_off)!, p.background);
        final r = _contrast(painted, p.background);
        expect(r, greaterThanOrEqualTo(1.5),
            reason: '${pack.name}：关态轨道 ${_hex(st.trackColor!.resolve(_off)!)} '
                '压到底色 ${_hex(p.background)} 上 = ${_hex(painted)}，'
                '对比度 ${r.toStringAsFixed(2)}:1');
      });
    }
  });
}
